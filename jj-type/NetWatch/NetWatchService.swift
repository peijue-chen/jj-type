//
//  NetWatchService.swift
//  jj-type
//
//  The network watchdog state machine. One timer drives everything:
//  probe → decide → act → notify. Blocking work (ping/curl/networksetup)
//  runs on a detached task; state changes stay on the main actor.
//
//  Flow on an outage:
//    network down → wait outageThreshold → join backup Wi-Fi → verify →
//    (optional) restart VPN → (optional) launch app → webhook → cooldown.
//

import AppKit

extension Notification.Name {
    static let netWatchStatusChanged = Notification.Name("jjtype.netWatch.statusChanged")
}

enum NetWatchPhase: Equatable {
    case disabled
    case healthy
    case networkDown(since: Date)
    case switching
    case recovering
    case vpnDown(since: Date)
    case failed(reason: String)

    var title: String {
        switch self {
        case .disabled: return "已停用"
        case .healthy: return "正常"
        case .networkDown: return "网络断开"
        case .switching: return "正在切换备用网络"
        case .recovering: return "正在恢复"
        case .vpnDown: return "VPN 断开"
        case .failed: return "失败"
        }
    }

    var isDown: Bool {
        switch self {
        case .networkDown, .switching, .failed: return true
        default: return false
        }
    }

    /// A real outage (link/switch/VPN), as opposed to a healthy tick or a
    /// transient state. Used to decide whether returning to `.healthy` counts
    /// as a recovery worth re-anchoring the heartbeat window for.
    var isOutage: Bool {
        switch self {
        case .networkDown, .switching, .failed, .vpnDown, .recovering: return true
        case .disabled, .healthy: return false
        }
    }
}

@MainActor
final class NetWatchService {
    static let shared = NetWatchService()

    private(set) var config = NetWatchConfig.default
    private(set) var phase: NetWatchPhase = .disabled
    private(set) var lastCheck: Date?
    private(set) var lastSwitch: Date?
    private(set) var lastRecovery: Date?
    private(set) var lastError: String?
    private(set) var lastProbeDetail = ""

    /// Last layer written to the log and when. A healthy 30 s tick used to
    /// append an identical "overseasOK" line every time (204 of 282 lines in a
    /// real log), which rotated away the incident that actually mattered.
    private var lastLoggedLayer: String?
    private var lastLoggedAt: Date?
    /// Throttles the "backupSSID empty" skip line during a long outage.
    private var lastSkipLogAt: Date?

    /// Anchor for the heartbeat interval, PERSISTED (`UserDefaults`) so an app
    /// restart does not silently restart the count.
    ///
    /// Memory-only was a real failure mode: with a 2 h interval and an app that
    /// is relaunched (or restarted by an update) more often than that, every
    /// start re-anchored to "now" and the heartbeat never came due at all.
    /// It is still re-anchored on a REAL recovery (so a heartbeat never lands
    /// right after a recovery notification) and on wake from sleep.
    private(set) var heartbeatClock: Date? {
        didSet {
            if let heartbeatClock {
                UserDefaults.standard.set(heartbeatClock.timeIntervalSince1970,
                                          forKey: Self.heartbeatClockKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.heartbeatClockKey)
            }
        }
    }

    private static let heartbeatClockKey = "netWatch.heartbeatClock"
    /// Last time a heartbeat webhook was actually delivered (shown in the UI).
    private(set) var lastHeartbeatSent: Date?
    /// After a failed heartbeat send, wait this long before trying again so a
    /// broken endpoint is not hammered on every 30 s tick.
    private var heartbeatRetryAt: Date?
    /// Why the last heartbeat evaluation declined to send. Logged ONCE per
    /// change (not per tick) — a silent `guard` with no log line is what made
    /// "heartbeats stopped and nothing was recorded" undebuggable.
    private var heartbeatSkippedReason: String?
    /// `NSWorkspace.didWakeNotification` token, so the observer is installed
    /// once and removed on stop().
    private var wakeObserver: NSObjectProtocol?

    /// Fired on every state change so the menu can rebuild.
    var onStatusChanged: (() -> Void)?

    /// Set once an outage has been handled. `handle()` treats a reachable
    /// network as "recovering" only when a switch actually happened — without
    /// this flag a `failed` phase (e.g. "joined but still unusable") would
    /// re-run the full VPN + app + webhook chain on every single tick.
    private var needsRecovery = false

    private weak var store: SettingsStore?
    private var timer: Timer?
    private var isChecking = false
    /// Single-flight guards: a long action must not be started twice by the
    /// next timer tick while it is still running.
    private var isSwitching = false
    private var isRestartingVPN = false
    private var isRecovering = false
    private var consecutiveFailures = 0
    /// When the CURRENT outage began, PERSISTED (`UserDefaults`) so a `kill -9`
    /// during an outage does not restart the 断网判定 countdown.
    ///
    /// In-memory only was a real gap: the app was killed mid-outage, and on
    /// relaunch `outageStart` was nil again, so the watchdog waited the FULL
    /// `outageThresholdSeconds` (10 min by default) before switching to the
    /// backup network — even though the network had already been down for
    /// hours. A switch is exactly what the user wants most while the app is
    /// being restarted.
    ///
    /// Bounded by `outageStaleLimit`: an anchor older than that is dropped,
    /// because the Mac may have been asleep or offline in another network for
    /// days and "an outage that started 3 days ago" is fiction (and would fire
    /// a switch notification with a nonsense duration).
    private var outageStart: Date? {
        didSet { persistOutageStart() }
    }
    private static let outageStartKey = "netWatch.outageStart"
    /// A persisted outage older than 24 h is ignored on start: too old to be
    /// the same incident.
    private static let outageStaleLimit: TimeInterval = 24 * 60 * 60

    private var vpnDownStart: Date?
    private var lastSwitchAttempt: Date?
    private var backoffUntil: Date?
    /// Consecutive failed VPN restarts + the exponential backoff deadline.
    private var vpnRestartFailures = 0
    private var vpnRestartBackoffUntil: Date?
    private var activity: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    func configure(store: SettingsStore) {
        self.store = store
        config = store.netWatchConfig
        if config.enabled { start() }
    }

    func updateConfig(_ newConfig: NetWatchConfig) {
        let previous = config
        let sanitized = newConfig.sanitized()
        config = sanitized
        store?.netWatchConfig = sanitized

        if sanitized.enabled {
            if timer == nil {
                start()
            } else if previous.checkIntervalSeconds != sanitized.checkIntervalSeconds {
                // Re-arm the timer: `start()` early-returns while a timer
                // exists, so without this a changed 检查间隔 only took effect
                // after an app restart.
                scheduleTimer()
                NetWatchLog.note("interval changed to \(sanitized.checkIntervalSeconds)s")
            }
        } else {
            stop()
        }

        // A heartbeat switch only acts when the toggle actually FLIPPED, and
        // never resets an anchor that is already counting: the settings page
        // only calls updateConfig() on a save, so a refresh of this page must
        // not throw the current window away.
        if !previous.heartbeatEnabled, sanitized.heartbeatEnabled {
            // Just switched on: a fresh interval instead of firing right away
            // on the next tick. A persisted anchor from an earlier session is
            // honoured (start() decides), so this is only the in-session case.
            if heartbeatClock == nil { heartbeatClock = Date() }
            heartbeatRetryAt = nil
            heartbeatSkippedReason = nil
            NetWatchLog.note("heartbeat enabled")
        } else if previous.heartbeatEnabled, !sanitized.heartbeatEnabled {
            heartbeatSkippedReason = nil
            NetWatchLog.note("heartbeat disabled")
        } else if previous.heartbeatEnabled, sanitized.heartbeatEnabled,
                  previous.heartbeatIntervalSeconds != sanitized.heartbeatIntervalSeconds {
            // A SHORTER interval must not wait out the old one: with 2 h
            // configured and a change to 10 min, the next heartbeat would
            // otherwise be hours away. Re-anchor only when the new interval has
            // not already elapsed, so an already-due heartbeat is not postponed
            // and the next tick sends it.
            let interval = TimeInterval(max(sanitized.heartbeatIntervalSeconds, 60))
            let elapsed = heartbeatClock.map { Date().timeIntervalSince($0) } ?? interval
            if elapsed < interval { heartbeatClock = Date() }
            heartbeatRetryAt = nil
            NetWatchLog.note("heartbeat interval changed to \(sanitized.heartbeatIntervalSeconds)s")
        }

        publishStatus()
    }

    func start() {
        guard config.enabled else { return }
        guard timer == nil else { return }
        phase = .healthy
        // Resume the persisted anchor instead of restarting the count: only a
        // FIRST run (no stored anchor) or a stale one (app was off far longer
        // than the interval — sending "still running" for a process that was
        // not running would be a lie) starts a fresh window.
        heartbeatRetryAt = nil
        heartbeatSkippedReason = nil
        let stored = UserDefaults.standard.double(forKey: Self.heartbeatClockKey)
        let interval = TimeInterval(max(config.heartbeatIntervalSeconds, 60))
        if stored > 0 {
            let anchor = Date(timeIntervalSince1970: stored)
            let age = Date().timeIntervalSince(anchor)
            if age >= 0, age < interval * 2 {
                heartbeatClock = anchor
                NetWatchLog.note("heartbeat anchor restored (age \(Int(age))s)")
            } else {
                heartbeatClock = Date()
                NetWatchLog.note("heartbeat anchor too old (\(Int(age))s), restarting")
            }
        } else {
            // First heartbeat lands one full interval after the service starts.
            heartbeatClock = Date()
        }
        // Resume an outage that was already in progress when this process died.
        // Without it a `kill -9` mid-outage restarted the whole 断网判定
        // countdown, delaying the backup-Wi-Fi switch the user was waiting for.
        restoreOutageStart()
        // While the Mac sleeps the timer does not fire, so a nap longer than
        // the interval would otherwise swallow a whole heartbeat window and
        // send the next one only after ANOTHER full interval. Re-anchor on
        // wake: the heartbeat then resumes on the normal cadence.
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            }
        }
        beginActivity()
        scheduleTimer()
        NetWatchLog.note("service started interval=\(config.checkIntervalSeconds)s")
        checkNow()
        publishStatus()
    }

    /// Stops the watchdog.
    ///
    /// `preservingOutage` distinguishes the two very different reasons for
    /// stopping:
    ///   - the USER disabled the watchdog → the outage (if any) is not ours to
    ///     remember; re-enabling must start from a clean slate, otherwise a
    ///     stale `needsRecovery` / `outageStart` would switch Wi-Fi the moment
    ///     the toggle comes back on.
    ///   - the PROCESS is going away (quit / app update / relaunch) → an outage
    ///     that is in progress must SURVIVE, exactly like the `kill -9` case,
    ///     or a relaunch mid-outage waits out a whole fresh threshold.
    func stop(preservingOutage: Bool = false) {
        // Idempotent: the settings page saves on every keystroke and calls
        // updateConfig() each time, so a disabled watchdog used to append
        // "service stopped" dozens of times in a row.
        guard timer != nil || phase != .disabled else { return }
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        endActivity()
        // Drop every transient state: re-enabling later must start from a clean
        // slate, otherwise a stale `needsRecovery` / `outageStart` would fire a
        // VPN restart and an app launch the user never triggered.
        needsRecovery = false
        consecutiveFailures = 0
        if !preservingOutage {
            // Clearing this also erases the PERSISTED anchor (see didSet).
            outageStart = nil
        }
        vpnDownStart = nil
        lastSwitchAttempt = nil
        backoffUntil = nil
        isChecking = false
        lastError = nil
        // A quit/relaunch keeps the heartbeat anchor for the same reason as the
        // outage anchor: an app restarted more often than the interval would
        // otherwise never reach a heartbeat. The anchor is still bounded on
        // start() (see restore), so a long absence cannot replay an old window.
        if !preservingOutage {
            heartbeatClock = nil
        }
        heartbeatRetryAt = nil
        heartbeatSkippedReason = nil
        lastLoggedLayer = nil
        lastLoggedAt = nil
        lastSkipLogAt = nil
        phase = .disabled
        NetWatchLog.note("service stopped")
        publishStatus()
    }

    // MARK: - Outage persistence

    private func persistOutageStart() {
        if let outageStart {
            UserDefaults.standard.set(outageStart.timeIntervalSince1970,
                                      forKey: Self.outageStartKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.outageStartKey)
        }
    }

    /// Reloads the outage anchor written by a previous process.
    ///
    /// The value is READ BEFORE any assignment: `outageStart`'s `didSet`
    /// rewrites the stored key, so clearing the property first would delete the
    /// very value being restored (an easy self-inflicted bug).
    private func restoreOutageStart() {
        let stored = UserDefaults.standard.double(forKey: Self.outageStartKey)
        guard stored > 0 else { return }
        let anchor = Date(timeIntervalSince1970: stored)
        let age = Date().timeIntervalSince(anchor)
        if age < 0 || age > Self.outageStaleLimit {
            // Drop the stale default so the next real outage starts clean.
            outageStart = nil
            NetWatchLog.note("outage anchor discarded (age \(Int(age))s)")
            return
        }
        // Restored as a SUSPICION only: the probe this start() triggers decides
        // whether the network is really still down, and `handle()` clears the
        // anchor on the first `.overseasOK` tick. Marking it here means a still
        // broken network switches to the backup Wi-Fi immediately instead of
        // waiting out a fresh threshold.
        outageStart = anchor
        NetWatchLog.note("outage anchor restored (in progress for \(Int(age))s)")
    }

    // MARK: - Manual actions

    func checkNow() {
        guard config.enabled, !isChecking else { return }
        // A VPN restart can take minutes (two full kill+launch cycles). Probing
        // during it would read "vpn down" and re-enter the restart path, so the
        // tick is skipped until the current action finishes.
        guard !isRestartingVPN, !isSwitching, !isRecovering else { return }
        isChecking = true
        let cfg = config
        Task { [weak self] in
            // One call answers all three layers (link → overseas → domestic).
            // The VPN service state is no longer part of the verdict: an
            // overseas URL that actually opens is the proof, and it also covers
            // VPNs that are not provided by a system VPN service.
            let connectivity = await Task.detached {
                NetWatchProbe.probeConnectivity(overseasURL: cfg.overseasProbeURL,
                                               domesticURL: cfg.domesticProbeURL)
            }.value
            // `handle` clears the flag on the normal path. When the service is
            // already gone there is nothing left to freeze, so a plain `if let`
            // is enough — the old `self?.handle` left `isChecking` stuck true
            // whenever a probe outlived a re-created service.
            if let self {
                self.handle(connectivity: connectivity, config: cfg)
            }
        }
    }

    /// Joins the backup Wi-Fi immediately, bypassing the outage threshold.
    ///
    /// A manual switch is a user-initiated action, NOT an outage: it must never
    /// leave `needsRecovery` set, or the next successful probe would fire the
    /// whole VPN + app + webhook chain the user never asked for.
    func switchNow() {
        guard config.enabled else { return }
        let cfg = config
        Task { [weak self] in
            await self?.runSwitch(config: cfg, manual: true)
        }
    }

    func sendTestWebhook() async -> Bool {
        guard config.webhookEnabled, !config.webhookURL.isEmpty else { return false }
        let message = NetWatchMessage(
            kind: .test,
            reason: "用户在设置页手动点击了「发送测试通知」",
            result: "Webhook 链路连通，通知可正常送达",
            detail: "检查间隔 \(config.checkIntervalSeconds)s · 断网判定 \(config.outageThresholdSeconds)s")
        return await NetWatchWebhook.send(urlString: config.webhookURL, text: message.text)
    }

    /// 「立即测试 VPN」 — user-initiated, so it bypasses the grace period and
    /// always uses the graceful path (never SIGKILL) to keep the GUI session.
    func testVPNNow() async -> Bool {
        // Never compete with the watchdog for the VPN app: a second concurrent
        // kill+launch would leave two instances and an unpredictable tunnel.
        guard !isRestartingVPN else { return false }
        isRestartingVPN = true
        defer { isRestartingVPN = false }

        let cfg = config
        // "Is the VPN working?" is answered by the overseas link, so a VPN that
        // is not a system VPN service is judged correctly too.
        let current = await Task.detached { NetWatchProbe.httpProbe(url: cfg.overseasProbeURL) }.value
        if current.reachable {
            vpnRestartFailures = 0
            vpnRestartBackoffUntil = nil
            return true
        }
        // `restartVPN` polls the overseas link itself; its result is the verdict.
        let ok = await Task.detached {
            NetWatchProbe.restartVPN(appPath: cfg.vpnAppPath,
                                     verifyURL: cfg.overseasProbeURL,
                                     waitSeconds: cfg.vpnWaitSeconds)
        }.value
        if ok {
            vpnDownStart = nil
            vpnRestartFailures = 0
            vpnRestartBackoffUntil = nil
        }
        return ok
    }

    // MARK: - State machine

    /// Three-layer decision, in the order the user asked for.
    ///
    ///   noLink      → 基本网络都不通：直接走「备用网络 → OpenVPN → App」
    ///   localOnly   → 国内通、国外不通：只重启 OpenVPN，不动网络
    ///   overseasOK  → 国外真的能访问：健康（顺带跑一次待办恢复链）
    ///
    /// The VPN service state is intentionally NOT consulted here — the overseas
    /// URL is the ground truth, which also covers VPNs that are not a system
    /// VPN service.
    private func handle(connectivity: Connectivity, config: NetWatchConfig) {
        isChecking = false
        // A probe can outlive a stop() (the watchdog was disabled while the
        // request was in flight). Acting on it would flip the phase back to
        // .healthy and show "正常" while the timer is already gone.
        guard self.config.enabled else { return }
        lastCheck = Date()
        lastProbeDetail = connectivity.detail
        // A layer change always logs; a repeated layer logs once per 30 min
        // when healthy and once per 5 min when degraded, so a long outage stays
        // readable without flooding the file.
        let shouldLog = shouldLogCheck(connectivity)
        if shouldLog {
            NetWatchLog.note("check layer=\(layerName(connectivity)) detail=\(connectivity.detail)")
        }

        switch connectivity {
        case .overseasOK:
            // Captured before the phase is mutated: a transition from anything
            // other than `.healthy` means the network just came back, and the
            // heartbeat window must restart from that moment.
            let wasHealthy = phase == .healthy
            // A real link/VPN outage (as opposed to a transient blip) — see
            // the heartbeat note below.
            let wasDown = phase.isOutage
            consecutiveFailures = 0
            // READ THE DURATION BEFORE CLEARING THE ANCHOR. This used to be the
            // other way round, so `outageDuration` always saw a nil start and
            // the recovery notification reported "未能确定中断时长" for every
            // real outage.
            let outage = outageDuration
            outageStart = nil
            if needsRecovery {
                needsRecovery = false
                Task { [weak self] in
                    await self?.runRecovery(config: config, connectivity: connectivity,
                                            outageSeconds: outage)
                }
            } else {
                phase = .healthy
                vpnDownStart = nil
                // Healthy again: forget the failure history so a future incident
                // starts from a 2-minute backoff, not a 30-minute one.
                vpnRestartFailures = 0
                vpnRestartBackoffUntil = nil
            }
            // Only a genuine RECOVERY re-anchors the heartbeat. A transient
            // flip into `localOnly`/`vpnDown` (a VPN reconnect hiccup, which is
            // common overnight) used to reset the clock on every return, so
            // with a long interval the heartbeat could be postponed forever —
            // the exact "one heartbeat at 2 am, then nothing" symptom.
            //
            // `wasDown` is the second half of the fix: an `.overseasOK` probe
            // after a long outage is a real recovery and deserves a fresh
            // window (the recovery notification just went out), but a flip
            // back from a brief `localOnly`/`failed` blip must not defer a
            // heartbeat that is already due.
            if !wasHealthy, wasDown {
                heartbeatClock = Date()
                heartbeatRetryAt = nil
                NetWatchLog.note("heartbeat anchor reset after recovery")
            }
            if config.webhookEnabled {
                Task { await NetWatchWebhook.flush(urlString: config.webhookURL) }
            }
            maybeSendHeartbeat(config: config)

        case .localOnly(let domestic, let overseas):
            // The whole network is fine, only the road abroad is broken.
            // Switching Wi-Fi would be pointless — restart OpenVPN instead.
            if shouldLog {
                NetWatchLog.note("overseas unreachable (\(overseas)) but domestic ok → \(config.vpnTestEnabled ? "restart vpn" : "vpn checks disabled")")
            }
            consecutiveFailures = 0
            outageStart = nil
            guard config.vpnTestEnabled else {
                // The user turned VPN handling off, so nothing is restarted.
                // Do NOT report `.healthy` though: the overseas link is still
                // down, and a green "正常" would hide that.
                vpnDownStart = nil
                phase = .failed(reason: "国外不可访问（已关闭 VPN 自动处理）")
                lastError = "国外不可访问：国内正常（\(domestic)），国外失败（\(overseas)）"
                break
            }
            handleVPNDown(config: config, overseasBlocked: true, shouldLog: shouldLog)
            if config.webhookEnabled {
                Task { await NetWatchWebhook.flush(urlString: config.webhookURL) }
            }

        case .noLink(let reason):
            // Not even the domestic internet works. Do not call any API yet —
            // this is the "switch to the backup line, then bring the VPN up"
            // road, which is exactly what runSwitch() does.
            if shouldLog {
                NetWatchLog.note("no link (\(reason)) → backup network path")
            }
            consecutiveFailures += 1
            if outageStart == nil {
                outageStart = Date()
                NetWatchLog.note("outage started, threshold \(config.outageThresholdSeconds)s")
            }
            phase = .networkDown(since: outageStart ?? Date())
            if shouldSwitch(config: config) {
                // Mark now, not after the switch: the switch may legitimately
                // fail, and the next reachable tick must still run the recovery
                // chain once instead of silently declaring "healthy".
                needsRecovery = true
                Task { [weak self] in await self?.runSwitch(config: config) }
            }
        }
        publishStatus()
    }

    private func layerName(_ connectivity: Connectivity) -> String {
        switch connectivity {
        case .noLink: return "noLink"
        case .localOnly: return "localOnly"
        case .overseasOK: return "overseasOK"
        }
    }

    /// Rate-limits the per-tick "check" lines: true on a layer change, or when
    /// the current layer has not been logged for its interval (30 min healthy,
    /// 5 min degraded). Keeps the log proportional to events, not to ticks.
    private func shouldLogCheck(_ connectivity: Connectivity) -> Bool {
        let layer = layerName(connectivity)
        let healthy: Bool
        if case .overseasOK = connectivity { healthy = true } else { healthy = false }
        let interval: TimeInterval = healthy ? 30 * 60 : 5 * 60
        let now = Date()
        if layer == lastLoggedLayer, let last = lastLoggedAt,
           now.timeIntervalSince(last) < interval {
            return false
        }
        lastLoggedLayer = layer
        lastLoggedAt = now
        return true
    }

    /// Seconds since the outage started (0 when the network never went down).
    private var outageDuration: Int {
        guard let outageStart else { return 0 }
        return Int(Date().timeIntervalSince(outageStart))
    }

    /// Human-readable "how long the network was down" for the notification.
    private func outageText(_ seconds: Int) -> String {
        if seconds <= 0 { return "未能确定中断时长" }
        if seconds < 60 { return "约 \(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "约 \(minutes) 分钟" }
        return "约 \(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    // MARK: - Heartbeat

    /// Sends the periodic "still running" webhook.
    ///
    /// Called from the healthy branch of `handle()`, i.e. on the normal probe
    /// tick — there is no dedicated timer. The heartbeat only fires once the
    /// configured interval has elapsed, so with a 30 s check interval it lands
    /// within 30 s of the target.
    ///
    /// Deliberately uses `NetWatchWebhook.send` (not `deliver`): a heartbeat is
    /// only meaningful "now", so a failed one must NOT enter the offline queue
    /// and get replayed hours later next to a real alert.
    private func maybeSendHeartbeat(config: NetWatchConfig) {
        let now = Date()

        // Every rejection reason is logged once per change. A bare `return`
        // used to make a stalled heartbeat invisible in netwatch.log.
        func skip(_ reason: String) {
            guard heartbeatSkippedReason != reason else { return }
            heartbeatSkippedReason = reason
            NetWatchLog.note("heartbeat skipped: \(reason)")
        }

        guard config.heartbeatEnabled else { return skip("disabled") }
        guard config.webhookEnabled, !config.webhookURL.isEmpty else {
            return skip("webhook disabled or URL empty")
        }
        guard !needsRecovery, phase == .healthy else {
            return skip("not healthy (phase=\(phase.title) needsRecovery=\(needsRecovery))")
        }
        if let heartbeatRetryAt, now < heartbeatRetryAt {
            return skip("retry backoff until \(Int(heartbeatRetryAt.timeIntervalSince(now)))s")
        }

        guard let clock = heartbeatClock else {
            heartbeatClock = now
            return skip("no anchor yet, starting a fresh interval")
        }

        let interval = TimeInterval(max(config.heartbeatIntervalSeconds, 60))
        let elapsed = now.timeIntervalSince(clock)
        guard elapsed >= interval else { return }

        heartbeatSkippedReason = nil

        // Claim the slot before the async send so a slow webhook cannot make
        // the next tick send a second heartbeat.
        heartbeatClock = now
        heartbeatRetryAt = nil

        let message = NetWatchMessage(
            kind: .heartbeat,
            reason: "距上次心跳 \(durationText(elapsed))",
            result: "网络正常，守护进程仍在运行",
            detail: "检查间隔 \(config.checkIntervalSeconds)s · 心跳间隔 \(config.heartbeatIntervalSeconds)s")
        NetWatchLog.note("heartbeat sending (interval elapsed \(Int(elapsed))s)")

        Task { [weak self] in
            let ok = await NetWatchWebhook.send(urlString: config.webhookURL, text: message.text)
            guard let self else { return }
            if ok {
                self.lastHeartbeatSent = Date()
                self.heartbeatSkippedReason = nil
                NetWatchLog.note("heartbeat sent")
                // Refresh the settings page / menu so 「上次心跳」 updates.
                self.publishStatus()
            } else {
                // Roll the clock back so the next attempt still counts as "due",
                // and gate it for 5 minutes so a broken endpoint is not hit on
                // every tick.
                //
                // Only if nothing else has moved the clock in the meantime: a
                // recovery (or a stop/start) resets it to "now", and that must
                // win — otherwise a slow failing send would resurrect a stale
                // anchor and fire an early heartbeat right after recovery.
                if self.heartbeatClock == now {
                    self.heartbeatClock = clock
                    self.heartbeatRetryAt = Date().addingTimeInterval(300)
                    NetWatchLog.note("heartbeat failed, retry in 300s")
                } else {
                    NetWatchLog.note("heartbeat failed (clock already reset, next attempt after a full interval)")
                }
            }
        }
    }

    /// "约 2 小时 3 分钟" style duration for the heartbeat message.
    private func durationText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "约 \(hours) 小时 \(minutes) 分钟" }
        if minutes > 0 { return "约 \(minutes) 分钟" }
        return "约 \(total) 秒"
    }

    private func shouldSwitch(config: NetWatchConfig) -> Bool {
        guard let outageStart else { return false }
        guard Date().timeIntervalSince(outageStart) >= Double(config.outageThresholdSeconds) else { return false }
        if let backoffUntil, Date() < backoffUntil { return false }
        if let lastSwitchAttempt,
           Date().timeIntervalSince(lastSwitchAttempt) < Double(config.switchCooldownSeconds) {
            return false
        }
        return true
    }

    /// Grace-then-restart logic for a VPN that is not connected.
    ///
    /// `domestic` tells whether the physical internet is alive. When it is, the
    /// tunnel is not merely "not yet connected" but half-open (its default
    /// route is still installed, which is why only overseas hosts fail), so the
    /// restart escalates to a SIGKILL.
    /// The road abroad is blocked (domestic still works). This is the case the
    /// user described as "重启 OpenVPN（关掉再打开）".
    ///
    /// `overseasBlocked` is true when the overseas URL failed while the domestic
    /// one answered — a half-open tunnel is the most likely cause, so the
    /// restart goes straight to SIGKILL instead of the graceful `--quit`.
    private func handleVPNDown(config: NetWatchConfig, overseasBlocked: Bool, shouldLog: Bool) {
        if vpnDownStart == nil {
            vpnDownStart = Date()
            NetWatchLog.note("overseas blocked detected (domestic ok) — will restart vpn")
        }
        phase = .vpnDown(since: vpnDownStart ?? Date())
        guard !isRestartingVPN else { return }
        guard let vpnDownStart else { return }
        // After a failed restart the watchdog waits out an exponential backoff
        // instead of immediately retrying on the next grace cycle.
        if let vpnRestartBackoffUntil, Date() < vpnRestartBackoffUntil {
            return
        }
        let elapsed = Date().timeIntervalSince(vpnDownStart)
        if shouldLog {
            NetWatchLog.note("overseas blocked \(Int(elapsed))s / \(config.vpnGraceSeconds)s")
        }
        guard elapsed >= Double(config.vpnGraceSeconds) else { return }
        Task { [weak self] in
            await self?.restartVPNOnly(config: config, hardFirst: overseasBlocked)
        }
    }

    // MARK: - Actions

    /// Joins the backup Wi-Fi and runs the post-switch chain.
    ///
    /// `manual` distinguishes the user's 「立即切换备用网络」 button from an
    /// automatic outage response: a manual switch must not mark the watchdog as
    /// "recovering from an outage", and must not fire the VPN/app chain on the
    /// next tick if it fails.
    private func runSwitch(config: NetWatchConfig, manual: Bool = false) async {
        guard config.enabled, !isSwitching else { return }
        guard !config.backupSSID.isEmpty else {
            lastError = "未配置备用 Wi-Fi"
            // A misconfigured watchdog retries on every tick, so this line
            // would otherwise repeat for the whole outage. A manual click
            // always logs; the automatic path logs once per 5 min.
            if manual || lastSkipLogAt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
                lastSkipLogAt = Date()
                NetWatchLog.note("switch skipped: backupSSID empty")
            }
            return
        }
        isSwitching = true
        defer { isSwitching = false }
        phase = .switching
        lastSwitchAttempt = Date()
        publishStatus()
        NetWatchLog.note("switching to backup ssid=\(config.backupSSID) manual=\(manual)")

        let password = KeychainStore.loadWiFiPassword(ssid: config.backupSSID) ?? ""
        let interface = config.wifiInterface.isEmpty
            ? NetWatchProbe.detectWiFiInterface()
            : config.wifiInterface
        let joined = await Task.detached {
            NetWatchProbe.joinWiFi(interface: interface,
                                   ssid: config.backupSSID,
                                   password: password,
                                   // Automatic outage: keep the radio on so the
                                   // next retry does not have to power-cycle it.
                                   keepPoweredOn: !manual)
        }.value

        guard joined else {
            lastError = "无法连接备用 Wi-Fi \(config.backupSSID)"
            phase = .failed(reason: lastError ?? "")
            backoffUntil = Date().addingTimeInterval(300)
            // Only a MANUAL switch clears the recovery flag: an automatic one
            // means the outage is still in progress, so the flag must survive
            // or the VPN/app chain would be silently skipped when the network
            // eventually comes back on its own.
            if manual { needsRecovery = false }
            NetWatchLog.note("switch failed: \(lastError ?? "") (manual=\(manual))")
            await notify(config: config, message: NetWatchMessage(
                kind: .switchFailed,
                reason: "主网络中断 \(outageText(outageDuration))",
                result: "加入备用 Wi-Fi「\(config.backupSSID)」失败，将在 5 分钟后重试",
                detail: "网卡 \(interface)"))
            publishStatus()
            return
        }

        // Verify with the same layered probe: after joining the backup network,
        // the domestic link must come up. The overseas link is brought up by the
        // next step (OpenVPN), so only `.noLink` counts as a failed switch.
        var connectivity = Connectivity.noLink(reason: "not probed")
        for _ in 0..<12 {
            connectivity = await Task.detached {
                NetWatchProbe.probeConnectivity(overseasURL: config.overseasProbeURL,
                                                domesticURL: config.domesticProbeURL)
            }.value
            if connectivity.hasInternet { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        guard connectivity.hasInternet else {
            lastError = "已连接 \(config.backupSSID)，但网络仍不可用"
            phase = .failed(reason: lastError ?? "")
            backoffUntil = Date().addingTimeInterval(300)
            if manual {
                // The user is still on a broken network and expects the
                // watchdog to keep trying; the outage is real.
                needsRecovery = true
            }
            NetWatchLog.note("switch joined but network unreachable: \(connectivity.detail)")
            await notify(config: config, message: NetWatchMessage(
                kind: .networkUnusable,
                reason: "主网络中断 \(outageText(outageDuration))，需要切换备用网络",
                result: "已加入备用 Wi-Fi「\(config.backupSSID)」，但探测不到外网，将在 5 分钟后重试",
                detail: connectivity.detail))
            publishStatus()
            return
        }

        lastSwitch = Date()
        lastError = nil
        NetWatchLog.note("switch succeeded ssid=\(config.backupSSID) layer=\(layerName(connectivity))")
        // The switch itself completes the outage; the recovery chain (VPN /
        // app / webhook) runs once, here, with the real outage duration.
        needsRecovery = false
        await runRecovery(config: config, connectivity: connectivity,
                          outageSeconds: outageDuration,
                          switchedTo: config.backupSSID)
    }

    /// Runs the post-outage chain once: VPN → app → notification.
    ///
    /// `outageSeconds` and `switchedTo` only feed the notification text; the
    /// actions themselves do not depend on them. `connectivity` decides whether
    /// the VPN actually needs restarting: if the overseas link is already up
    /// (the network itself may be a VPN), nothing is restarted.
    private func runRecovery(config: NetWatchConfig,
                             connectivity: Connectivity,
                             outageSeconds: Int,
                             switchedTo: String? = nil) async {
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }
        phase = .recovering
        publishStatus()

        var vpnResult: Bool?
        if config.vpnTestEnabled {
            if connectivity.overseasReachable {
                vpnResult = true
            } else {
                NetWatchLog.note("overseas still blocked after recovery, restarting vpn")
                // The domestic link just came up, so the blockage is the road
                // abroad: kill the (possibly half-open) client and start over.
                vpnResult = await Task.detached {
                    NetWatchProbe.restartVPN(appPath: config.vpnAppPath,
                                             verifyURL: config.overseasProbeURL,
                                             waitSeconds: config.vpnWaitSeconds,
                                             hardFirst: true)
                }.value
            }
        }

        var appResult: Bool?
        if config.launchAppEnabled, !config.launchAppPath.isEmpty {
            appResult = await Task.detached {
                NetWatchProbe.launchApp(path: config.launchAppPath)
            }.value
        }

        lastRecovery = Date()
        let success = (vpnResult ?? true) && (appResult ?? true)
        if success {
            phase = .healthy
            lastError = nil
            vpnDownStart = nil
            vpnRestartFailures = 0
            vpnRestartBackoffUntil = nil
            // Recovery just finished: restart the heartbeat window here so the
            // first heartbeat is a full interval after the network came back,
            // not immediately after the recovery notification.
            heartbeatClock = Date()
            heartbeatRetryAt = nil
            heartbeatSkippedReason = nil
            NetWatchLog.note("heartbeat anchor reset after recovery completed")
        } else {
            phase = .failed(reason: "恢复后 VPN 或 App 启动失败")
            lastError = "恢复后 VPN 或 App 启动失败"
            if vpnResult == false {
                // A failed VPN restart during recovery enters the same backoff
                // ladder as a standalone restart, so the two paths cannot
                // hammer the VPN app together.
                vpnRestartFailures += 1
                let delay = min(30.0 * 60.0, 120.0 * pow(2.0, Double(vpnRestartFailures - 1)))
                vpnRestartBackoffUntil = Date().addingTimeInterval(delay)
            }
        }
        publishStatus()

        let appName = (config.launchAppPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
        var results: [String] = []
        if let switchedTo {
            results.append("已切换到备用 Wi-Fi「\(switchedTo)」")
        } else {
            // "网络已恢复" is only truthful when the road abroad is back; a
            // switch that only restored the domestic link must not claim it.
            results.append(connectivity.overseasReachable ? "网络已恢复" : "国内网络已恢复，国外仍不可达")
        }
        if let vpnResult {
            results.append(vpnResult ? "VPN 已连接" : "VPN 连接失败")
        }
        if let appResult {
            results.append(appResult ? "已打开 \(appName)" : "打开 \(appName) 失败")
        }

        let kind: NetWatchMessage.Kind
        if success {
            kind = .recovered
        } else if vpnResult == false {
            kind = .vpnFailed
        } else {
            kind = .recovered
        }

        if success ? config.notifyOnSuccess : config.notifyOnFailure {
            await notify(config: config, message: NetWatchMessage(
                kind: kind,
                reason: switchedTo == nil
                    ? "主网络中断 \(outageText(outageSeconds))，现已重新连通"
                    : "主网络中断 \(outageText(outageSeconds))，需要切换备用网络",
                result: results.joined(separator: "；"),
                detail: lastProbeDetail))
        }
    }

    /// Full VPN restart cycle: kill OpenVPN Connect, start it again and wait
    /// for the tunnel. `hardFirst` skips the graceful `--quit` and goes straight
    /// to SIGKILL (used when the tunnel is half-open).
    private func restartVPNOnly(config: NetWatchConfig, hardFirst: Bool) async {
        guard !isRestartingVPN else { return }
        isRestartingVPN = true
        defer { isRestartingVPN = false }
        phase = .recovering
        publishStatus()
        NetWatchLog.note("vpn restart start (hardFirst=\(hardFirst))")

        let outcome = await Task.detached { () -> (ok: Bool, domestic: Bool) in
            // `restartVPN` already polls the overseas link for `vpnWaitSeconds`
            // after relaunching, so its result IS the verdict — no second wait
            // loop here (that would add 12 s on top of an already long cycle).
            let overseas = NetWatchProbe.restartVPN(appPath: config.vpnAppPath,
                                                    verifyURL: config.overseasProbeURL,
                                                    waitSeconds: config.vpnWaitSeconds,
                                                    hardFirst: hardFirst)
            // Only when the tunnel did not come up is the domestic side worth
            // checking — it goes into the notification to tell "VPN fault" and
            // "network also broken" apart.
            let domestic = overseas ? false : NetWatchProbe.httpProbe(url: config.domesticProbeURL).reachable
            return (overseas, domestic)
        }.value

        let ok = outcome.ok
        if ok {
            vpnDownStart = nil
            vpnRestartBackoffUntil = nil
            vpnRestartFailures = 0
            phase = .healthy
            lastError = nil
        } else {
            // Do NOT clear vpnDownStart on failure: with it nil the next tick
            // would restart the grace period and kill the VPN again on every
            // grace cycle, forever. Back off exponentially instead (2, 4, 8 …
            // capped at 30 min) so a broken VPN profile cannot thrash the app.
            vpnRestartFailures += 1
            let delay = min(30.0 * 60.0, 120.0 * pow(2.0, Double(vpnRestartFailures - 1)))
            vpnRestartBackoffUntil = Date().addingTimeInterval(delay)
            phase = .failed(reason: "VPN 重连失败")
            lastError = "VPN 重连失败"
            NetWatchLog.note("vpn restart failed, backoff \(Int(delay))s (attempt \(vpnRestartFailures))")
        }
        NetWatchLog.note("vpn restart \(ok ? "succeeded" : "failed")")
        publishStatus()
        if ok ? config.notifyOnSuccess : config.notifyOnFailure {
            let result: String
            if ok {
                result = hardFirst
                    ? "已强制结束 OpenVPN Connect 进程并重新启动，隧道已恢复"
                    : "已重启 OpenVPN Connect 并重新建立隧道"
            } else if outcome.domestic {
                result = "多次强制重启后 VPN 仍未连上，但国内网络正常，请手动检查 VPN 账号或服务器"
            } else {
                result = "多次重启后 VPN 仍未连上，且国内网络也不可用"
            }
            await notify(config: config, message: NetWatchMessage(
                kind: ok ? .vpnRestored : .vpnFailed,
                reason: "国外链接连续 \(config.vpnGraceSeconds) 秒打不开（国内正常）",
                result: result,
                detail: "验证地址 \(config.overseasProbeURL)"))
        }
    }

    private func notify(config: NetWatchConfig, message: NetWatchMessage) async {
        guard config.webhookEnabled, !config.webhookURL.isEmpty else { return }
        await NetWatchWebhook.deliver(urlString: config.webhookURL, message: message)
    }

    // MARK: - Wake

    /// Re-anchors the heartbeat clock after the Mac wakes from sleep.
    ///
    /// A repeating `Timer` does NOT fire during sleep and coalesces the missed
    /// fires into one on wake, so `heartbeatClock` could be hours stale: the
    /// heartbeat would then be due immediately (one notification right after
    /// waking, often in the middle of the night) and, if the tick after it was
    /// interrupted, the cadence was lost for the rest of the session. Treating
    /// the wake as a fresh anchor keeps the interval honest — one heartbeat per
    /// interval of AWAKE time, never a burst on wake.
    ///
    /// The clock is only re-anchored, not the whole state: a real outage that
    /// started before the sleep must be detected normally by the probe this
    /// wake triggers.
    private func handleWake() {
        guard config.enabled, timer != nil else { return }
        let now = Date()
        let gap = heartbeatClock.map { now.timeIntervalSince($0) } ?? 0
        NetWatchLog.note("woke from sleep, heartbeat anchor reset (gap \(Int(gap))s)")
        heartbeatClock = now
        heartbeatRetryAt = nil
        heartbeatSkippedReason = nil
        // Probe right away: the network almost always changed while asleep
        // (Wi-Fi re-associated, VPN dropped), and waiting a full check
        // interval would report a stale "正常".
        checkNow()
    }

    // MARK: - Timer

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(config.checkIntervalSeconds, 10))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Bind strongly first: capturing the weak `self` var directly inside
            // the concurrently-executing Task is a Swift 6 error. The timer fires
            // on RunLoop.main, so this hop is only to satisfy actor isolation.
            guard let self else { return }
            Task { @MainActor in self.checkNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .suddenTerminationDisabled],
            reason: "NetWatch network watchdog")
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func publishStatus() {
        onStatusChanged?()
        NotificationCenter.default.post(name: .netWatchStatusChanged, object: nil)
    }
}
