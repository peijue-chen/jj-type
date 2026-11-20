//
//  InputSourceKeeper.swift
//  jj-type
//
//  Keeps a third-party input method (Sogou) selected across app switches.
//
//  Why this exists: macOS remembers the input source per app. When a
//  third-party IME is not fully registered with the system, the input source
//  silently falls back to ABC whenever focus moves to another app. macOS has
//  no setting to pin one IME globally (ABC cannot be removed — it is the
//  fallback keyboard layout), so this service re-selects the target source
//  through the Carbon TIS API. Carbon is already a dependency for the global
//  hotkeys, so no new framework is introduced.
//
//  Safety: nothing happens unless a Sogou input source is actually installed
//  AND enabled. If the user has not installed Sogou, the keeper stays inert
//  and the settings page / menu explain why.
//

import AppKit
import Carbon

/// How aggressively the keeper re-selects the target input source.
enum InputSourceKeeperMode: String, CaseIterable {
    /// Correct only when the frontmost app changes. A manual switch inside the
    /// same app is left alone.
    case onAppSwitch
    /// Correct on every input-source change. A manual switch to ABC is undone.
    case always

    var title: String {
        switch self {
        case .onAppSwitch: return "切换 App 时纠正"
        case .always: return "始终纠正"
        }
    }

    var detail: String {
        switch self {
        case .onAppSwitch:
            return "只在切换到别的 App 时把输入法切回搜狗，不干扰你在同一个 App 里手动切换。"
        case .always:
            return "任何时刻发现输入法不是搜狗就切回去，会阻止你手动切到 ABC。"
        }
    }
}

/// What the keeper found on this Mac.
enum InputSourceStatus: Equatable {
    /// No Sogou bundle in either Input Methods folder.
    case notInstalled
    /// Sogou is installed but the system has not enabled it as an input source.
    case installedButDisabled(bundleID: String)
    /// A usable Sogou input source is present.
    case ready(id: String, name: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .notInstalled:
            return "未检测到搜狗输入法"
        case .installedButDisabled(let bundleID):
            return "已安装（\(bundleID)），但系统尚未启用"
        case .ready(_, let name):
            return "已就绪：\(name)"
        }
    }
}

/// Re-selects a third-party input method when macOS falls back to ABC.
///
/// Deliberately conservative: it only acts when a Sogou input source is
/// present and enabled, and it never touches the system's own keyboard layouts.
final class InputSourceKeeper {
    static let shared = InputSourceKeeper()

    /// Fires when the enabled flag, the mode, or the detected status changes.
    var onChanged: (() -> Void)?

    private(set) var isEnabled = false
    private(set) var mode: InputSourceKeeperMode = .onAppSwitch
    private(set) var status: InputSourceStatus = .notInstalled
    /// Display name of the currently selected input source (for the UI).
    private(set) var currentSourceName: String?

    private var workspaceObserver: NSObjectProtocol?
    private var distributedObserver: NSObjectProtocol?

    /// Guards against re-entrancy: TISSelectInputSource fires the change
    /// notification again, which would otherwise re-enter correctNow().
    private var isCorrecting = false

    /// When the last successful correction happened. TISSelectInputSource
    /// fires the change notification itself, so without this the correction
    /// would schedule a second correction ~0.25 s later. If Sogou is still
    /// running its activateServer at that moment, TISCopyCurrentKeyboardInputSource
    /// may still report ABC and we would re-select Sogou mid-activation — which
    /// leaves its input controller without a valid client and breaks the
    /// Shift key (stuck in English until a full deactivate/activate cycle).
    private var lastCorrectionTime = Date.distantPast
    /// Ignore source-change notifications this soon after our own correction.
    private let correctionCooldown: TimeInterval = 1.0

    /// Delay before correcting a *source change* (always mode).
    ///
    /// Switching back instantly leaves Sogou stuck in English mode: the
    /// activate arrives while the deactivate is still in flight, so the IME's
    /// input controller never gets a valid client and stops handling key
    /// events — Shift no longer toggles Chinese/English. Waiting for the
    /// deactivate cycle to finish avoids that race.
    private let sourceChangeDelay: TimeInterval = 0.3
    /// Settle window for app switches. The system restores the app's remembered
    /// input source asynchronously after activation; correcting before that
    /// settles leaves Sogou's input controller without a valid client (Shift
    /// stops working). We wait until the source has been quiet for this long.
    private let appSwitchDelay: TimeInterval = 0.3
    /// Pending delayed correction; cancelled when a newer one is scheduled.
    private var pendingCorrection: Task<Void, Never>?
    /// Pending "settle then correct" pass (onAppSwitch mode only). Restarted
    /// every time the source changes while we are waiting, so we only switch
    /// after the system's restoration has finished.
    private var appSwitchSettleTask: Task<Void, Never>?
    /// How many times the current correction has been retried. Reset on success
    /// so a permanently failing switch cannot loop forever.
    private var retryCount = 0
    private let maxRetries = 1

    private init() {}

    // MARK: - Public control

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            // refreshStatus() installs the observers only when a Sogou source
            // is actually ready — enabling the keeper without Sogou installed
            // must not leave observers running.
            refreshStatus()
        } else {
            cancelPendingCorrection()
            cancelSettledCorrection()
            removeObservers()
        }
        onChanged?()
    }

    func setMode(_ mode: InputSourceKeeperMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        onChanged?()
    }

    /// Re-scans the system. Cheap enough to call when a menu or settings page
    /// opens; also starts/stops the observers when readiness changes.
    func refreshStatus() {
        let previous = status
        status = Self.detectStatus()
        currentSourceName = Self.currentSource()?.name

        if isEnabled {
            if status.isReady {
                installObserversIfNeeded()
            } else {
                removeObservers()
            }
        }
        if status != previous {
            onChanged?()
        }
    }

    /// Re-selects the target input source if it is not already active.
    /// Returns true when a switch was performed.
    @discardableResult
    func correctNow() -> Bool {
        guard isEnabled, case .ready(let targetID, _) = status else { return false }
        guard let current = Self.currentSource() else { return false }
        // Compare by "is this a Sogou source" rather than an exact ID: Sogou
        // exposes a parent source and an input-mode child, and the current
        // source may be either one.
        guard !Self.isSogou(current.id) else { return false }
        guard !isCorrecting else { return false }

        isCorrecting = true
        defer { isCorrecting = false }

        let switched = Self.selectSource(id: targetID)
        if switched {
            lastCorrectionTime = Date()
            retryCount = 0
        } else if retryCount < maxRetries {
            // The first attempt can fail while the system is still finishing
            // the previous switch. Retry once, then give up — a permanently
            // failing switch (e.g. Sogou uninstalled but status still stale)
            // must not loop forever.
            retryCount += 1
            scheduleCorrection(after: 0.4)
        } else {
            retryCount = 0
        }
        return switched
    }

    // MARK: - Observers

    private func installObserversIfNeeded() {
        guard workspaceObserver == nil else { return }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAppActivated()
            }
        }

        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSourceChanged()
            }
        }
    }

    private func removeObservers() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
    }

    private func handleAppActivated() {
        guard isEnabled, status.isReady else { return }
        // Clicking the jj-type menu-bar icon activates this app too. Switching
        // the input source just because the user opened our menu would be
        // surprising, so ignore activations of jj-type itself.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == Bundle.main.bundleIdentifier {
            return
        }
        scheduleSettledCorrection()
    }

    private func handleSourceChanged() {
        guard isEnabled, status.isReady else { return }
        switch mode {
        case .always:
            // Our own TISSelectInputSource fires this notification. Re-correcting
            // within the cooldown would re-select Sogou while it is still
            // activating, which breaks its Shift key (stuck in English).
            guard Date().timeIntervalSince(lastCorrectionTime) >= correctionCooldown else { return }
            // Always schedule; correctNow() re-checks the live source when the
            // delay elapses. Checking here would race the system: the
            // notification can arrive before TISCopyCurrentKeyboardInputSource
            // reflects the new source, which would make us skip a real switch.
            scheduleCorrection(after: sourceChangeDelay)
        case .onAppSwitch:
            // A source change while we are waiting to correct means the system
            // is still restoring the app's remembered input source. Restart the
            // wait so we switch only after it settles — switching mid-restoration
            // leaves Sogou's input controller without a valid client.
            if appSwitchSettleTask != nil {
                scheduleSettledCorrection()
            }
        }
    }

    /// Schedules a correction after `delay`, replacing any pending one. The
    /// delay lets the IME finish its deactivate cycle before we switch back —
    /// see `sourceChangeDelay` for why that matters.
    ///
    /// Cancels any pending settle correction: two timers firing milliseconds
    /// apart would re-select Sogou while it is still activating.
    private func scheduleCorrection(after delay: TimeInterval) {
        cancelPendingCorrection()
        cancelSettledCorrection()
        pendingCorrection = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pendingCorrection = nil
            self?.correctNow()
        }
    }

    private func cancelPendingCorrection() {
        pendingCorrection?.cancel()
        pendingCorrection = nil
    }

    /// Waits for the input source to stop changing, then corrects once.
    ///
    /// The system restores an app's remembered input source asynchronously
    /// after activation. Switching to Sogou while that restoration is still in
    /// flight leaves Sogou's input controller without a valid client, so Shift
    /// stops toggling Chinese/English. Every source change during the wait
    /// restarts the timer, so we only switch after the source has been quiet
    /// for `appSwitchDelay`.
    private func scheduleSettledCorrection() {
        cancelSettledCorrection()
        cancelPendingCorrection()
        appSwitchSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(appSwitchDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.appSwitchSettleTask = nil
            self.correctNow()
        }
    }

    private func cancelSettledCorrection() {
        appSwitchSettleTask?.cancel()
        appSwitchSettleTask = nil
    }
}

// MARK: - TIS plumbing

extension InputSourceKeeper {
    struct SourceInfo {
        let id: String
        let name: String
        let isEnabled: Bool
        let isSelectable: Bool
    }

    static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    static func allSources() -> [SourceInfo] {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else { return [] }
        let count = CFArrayGetCount(list)
        var result: [SourceInfo] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let source = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard let id = stringProperty(source, kTISPropertyInputSourceID) else { continue }
            result.append(SourceInfo(
                id: id,
                name: stringProperty(source, kTISPropertyLocalizedName) ?? id,
                isEnabled: boolProperty(source, kTISPropertyInputSourceIsEnabled),
                isSelectable: boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
            ))
        }
        return result
    }

    static func currentSource() -> SourceInfo? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let id = stringProperty(source, kTISPropertyInputSourceID) else { return nil }
        return SourceInfo(
            id: id,
            name: stringProperty(source, kTISPropertyLocalizedName) ?? id,
            isEnabled: true,
            isSelectable: true
        )
    }

    static func isSogou(_ id: String) -> Bool {
        id.lowercased().contains("sogou")
    }

    static func selectSource(id: String) -> Bool {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else { return false }
        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let source = Unmanaged<TISInputSource>.fromOpaque(raw).takeUnretainedValue()
            guard stringProperty(source, kTISPropertyInputSourceID) == id else { continue }
            return TISSelectInputSource(source) == noErr
        }
        return false
    }

    /// Prefers the Sogou source that is currently selected (so a user with both
    /// Wubi and Pinyin installed keeps the one they are actually using), then
    /// any selectable Sogou mode, then the parent source.
    static func detectStatus() -> InputSourceStatus {
        let sources = allSources()
        let sogou = sources.filter { isSogou($0.id) }
        let currentID = currentSource()?.id

        if let current = sogou.first(where: { $0.id == currentID && $0.isEnabled }) {
            return .ready(id: current.id, name: current.name)
        }
        if let ready = sogou.first(where: { $0.isEnabled && $0.isSelectable }) {
            return .ready(id: ready.id, name: ready.name)
        }
        if let parent = sogou.first(where: { $0.isEnabled }) {
            return .ready(id: parent.id, name: parent.name)
        }
        if let bundleID = installedSogouBundleID() {
            return .installedButDisabled(bundleID: bundleID)
        }
        return .notInstalled
    }

    /// Scans both Input Methods folders for a Sogou bundle. Used to tell
    /// "not installed" apart from "installed but not enabled".
    static func installedSogouBundleID() -> String? {
        let directories = [
            "/Library/Input Methods",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Input Methods"),
        ]
        for directory in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (directory as NSString).appendingPathComponent(entry)
                guard let bundle = Bundle(path: path) else { continue }
                let identifier = bundle.bundleIdentifier ?? entry
                if identifier.lowercased().contains("sogou") || entry.lowercased().contains("sogou") {
                    return identifier
                }
            }
        }
        return nil
    }
}
