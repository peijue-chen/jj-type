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

    /// Anchor for the heartbeat interval. Reset on start and on every recovery,
    /// so the count always begins at the moment the network came back — a
    /// heartbeat is never sent right after a recovery notification.
    private(set) var heartbeatClock: Date?
    /// Last time a heartbeat webhook was actually delivered (shown in the UI).
    private(set) var lastHeartbeatSent: Date?
    /// After a failed heartbeat send, wait this long before trying again so a
    /// broken endpoint is not hammered on every 30 s tick.
    private var heartbeatRetryAt: Date?

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
    private var outageStart: Date?
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

        // Turning the heartbeat on starts a fresh interval instead of firing
        // immediately on the next tick just because the app has been running
        // for a while.
        if !previous.heartbeatEnabled, sanitized.heartbeatEnabled {
            heartbeatClock = Date()
            heartbeatRetryAt = nil
        }

        publishStatus()
    }

    func start() {
        guard config.enabled else { return }
        guard timer == nil else { return }
        phase = .healthy
        // First heartbeat lands one full interval after the service starts.
        heartbeatClock = Date()
        heartbeatRetryAt = nil
        beginActivity()
        scheduleTimer()
        NetWatchLog.note("service started interval=\(config.checkIntervalSeconds)s")
        checkNow()
        publishStatus()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endActivity()
        // Drop every transient state: re-enabling later must start from a clean
        // slate, otherwise a stale `needsRecovery` / `outageStart` would fire a
        // VPN restart and an app launch the user never triggered.
        needsRecovery = false
        consecutiveFailures = 0
        outageStart = nil
        vpnDownStart = nil
        lastSwitchAttempt = nil
        backoffUntil = nil
        isChecking = false
        lastError = nil
        heartbeatClock = nil
        heartbeatRetryAt = nil
        phase = .disabled
        NetWatchLog.note("service stopped")
        publishStatus()
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
        lastCheck = Date()
        lastProbeDetail = connectivity.detail
        NetWatchLog.note("check layer=\(layerName(connectivity)) detail=\(connectivity.detail)")

        switch connectivity {
        case .overseasOK:
            // Captured before the phase is mutated: a transition from anything
            // other than `.healthy` means the network just came back, and the
            // heartbeat window must restart from that moment.
            let wasHealthy = phase == .healthy
            consecutiveFailures = 0
            outageStart = nil
            if needsRecovery {
                needsRecovery = false
                let outage = outageDuration
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
            if !wasHealthy {
                heartbeatClock = Date()
                heartbeatRetryAt = nil
            }
            if config.webhookEnabled {
                Task { await NetWatchWebhook.flush(urlString: config.webhookURL) }
            }
            maybeSendHeartbeat(config: config)

        case .localOnly(let domestic, let overseas):
            // The whole network is fine, only the road abroad is broken.
            // Switching Wi-Fi would be pointless — restart OpenVPN instead.
            NetWatchLog.note("overseas unreachable (\(overseas)) but domestic ok → \(config.vpnTestEnabled ? "restart vpn" : "vpn checks disabled")")
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
            handleVPNDown(config: config, overseasBlocked: true)
            if config.webhookEnabled {
                Task { await NetWatchWebhook.flush(urlString: config.webhookURL) }
            }

        case .noLink(let reason):
            // Not even the domestic internet works. Do not call any API yet —
            // this is the "switch to the backup line, then bring the VPN up"
            // road, which is exactly what runSwitch() does.
            NetWatchLog.note("no link (\(reason)) → backup network path")
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
        guard config.heartbeatEnabled,
              config.webhookEnabled,
              !config.webhookURL.isEmpty,
              !needsRecovery,
              phase == .healthy else { return }

        let now = Date()
        if let heartbeatRetryAt, now < heartbeatRetryAt { return }

        guard let clock = heartbeatClock else {
            heartbeatClock = now
            return
        }

        let interval = TimeInterval(max(config.heartbeatIntervalSeconds, 60))
        let elapsed = now.timeIntervalSince(clock)
        guard elapsed >= interval else { return }

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
    private func handleVPNDown(config: NetWatchConfig, overseasBlocked: Bool) {
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
        NetWatchLog.note("overseas blocked \(Int(elapsed))s / \(config.vpnGraceSeconds)s")
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
            NetWatchLog.note("switch skipped: backupSSID empty")
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
