//
//  InputSourceKeeper.swift
//  jj-type
//
//  Keeps a user-chosen input method selected across app switches.
//
//  Why this exists: macOS remembers the input source per app. When a
//  third-party IME is not fully registered with the system, the input source
//  silently falls back to ABC whenever focus moves to another app. macOS has
//  no setting to pin one IME globally (ABC cannot be removed — it is the
//  fallback keyboard layout), so this service re-selects the target source
//  through the Carbon TIS API. Carbon is already a dependency for the global
//  hotkeys, so no new framework is introduced.
//
//  Target: the user picks any enabled input source from the settings page or
//  the menu. When no target has been chosen yet, the keeper falls back to
//  Sogou so existing users keep working without re-configuring.
//
//  Safety: nothing happens unless the target input source is actually
//  installed AND enabled. Otherwise the keeper stays inert and the settings
//  page / menu explain why.
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
            return "只在切换到别的 App 时把输入法切回目标，不干扰你在同一个 App 里手动切换。"
        case .always:
            return "任何时刻发现输入法不是目标就切回去，会阻止你手动切到 ABC。"
        }
    }
}

/// What the keeper found on this Mac.
enum InputSourceStatus: Equatable {
    /// The target input source is not installed (or no target is available).
    case notInstalled
    /// The target is installed but the system has not enabled it.
    case installedButDisabled(bundleID: String)
    /// A usable target input source is present.
    case ready(id: String, name: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .notInstalled:
            return "未检测到目标输入法"
        case .installedButDisabled(let bundleID):
            return "已安装（\(bundleID)），但系统尚未启用"
        case .ready(_, let name):
            return "已就绪：\(name)"
        }
    }
}

/// Re-selects a user-chosen input method when macOS falls back to ABC.
///
/// Deliberately conservative: it only acts when the target input source is
/// present and enabled, and it never touches the system's own keyboard layouts.
final class InputSourceKeeper {
    static let shared = InputSourceKeeper()

    /// Fires when the enabled flag, the mode, the target or the detected status
    /// changes.
    var onChanged: (() -> Void)?

    private(set) var isEnabled = false
    private(set) var mode: InputSourceKeeperMode = .onAppSwitch
    private(set) var status: InputSourceStatus = .notInstalled
    /// Display name of the currently selected input source (for the UI).
    private(set) var currentSourceName: String?
    /// Input source ID the user chose to keep. `nil` means "auto": fall back to
    /// Sogou so existing users keep working without re-configuring.
    private(set) var targetID: String?

    /// Human-readable name for the menu title: the resolved target's name, or
    /// "搜狗" when the keeper is in auto mode.
    var targetDisplayName: String {
        if case .ready(_, let name) = status { return name }
        if let targetID {
            return Self.selectableSources()
                .first(where: { Self.isSameSource($0.id, targetID) })?.name ?? targetID
        }
        return "搜狗"
    }

    private var workspaceObserver: NSObjectProtocol?
    private var distributedObserver: NSObjectProtocol?

    /// Guards against re-entrancy: TISSelectInputSource fires the change
    /// notification again, which would otherwise re-enter correctNow().
    private var isCorrecting = false

    /// When the last successful correction happened. TISSelectInputSource
    /// fires the change notification itself, so without this the correction
    /// would schedule a second correction ~0.25 s later. If the IME is still
    /// running its activateServer at that moment, TISCopyCurrentKeyboardInputSource
    /// may still report ABC and we would re-select the target mid-activation —
    /// which leaves its input controller without a valid client and breaks the
    /// Shift key (stuck in English until a full deactivate/activate cycle).
    private var lastCorrectionTime = Date.distantPast
    /// Ignore source-change notifications this soon after our own correction.
    private let correctionCooldown: TimeInterval = 1.0

    /// Delay before correcting a *source change* (always mode).
    ///
    /// Switching back instantly leaves the IME stuck in English mode: the
    /// activate arrives while the deactivate is still in flight, so the IME's
    /// input controller never gets a valid client and stops handling key
    /// events — Shift no longer toggles Chinese/English. Waiting for the
    /// deactivate cycle to finish avoids that race.
    private let sourceChangeDelay: TimeInterval = 0.3
    /// Settle window for app switches. The system restores the app's remembered
    /// input source asynchronously after activation; correcting before that
    /// settles leaves the IME's input controller without a valid client (Shift
    /// stops working). We wait until the source has been quiet for this long.
    private let appSwitchDelay: TimeInterval = 0.5
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
            // refreshStatus() installs the observers only when the target
            // source is actually ready — enabling the keeper without the
            // target installed must not leave observers running.
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

    /// Chooses which input source to keep. `nil` restores the Sogou fallback.
    func setTarget(_ id: String?) {
        guard id != targetID else { return }
        targetID = id
        refreshStatus()
        onChanged?()
    }

    /// Re-scans the system. Cheap enough to call when a menu or settings page
    /// opens; also starts/stops the observers when readiness changes.
    func refreshStatus() {
        let previous = status
        status = Self.detectStatus(targetID: targetID)
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
        // Compare by "same source family" rather than an exact ID: an IME may
        // expose a parent source plus one child per input mode, and the current
        // source may be either one.
        guard !Self.isSameSource(current.id, targetID) else { return false }
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
            // within the cooldown would re-select the target while it is still
            // activating, which breaks its Shift key (stuck in English).
            guard Date().timeIntervalSince(lastCorrectionTime) >= correctionCooldown else { return }
            // A genuine external change starts a fresh correction cycle, so give
            // it a fresh retry budget. Without this, a retry cancelled by an app
            // switch would leave retryCount at its limit and the next cycle would
            // give up after a single failed attempt.
            retryCount = 0
            // Always schedule; correctNow() re-checks the live source when the
            // delay elapses. Checking here would race the system: the
            // notification can arrive before TISCopyCurrentKeyboardInputSource
            // reflects the new source, which would make us skip a real switch.
            scheduleCorrection(after: sourceChangeDelay)
        case .onAppSwitch:
            // A source change while we are waiting to correct means the system
            // is still restoring the app's remembered input source. Restart the
            // wait so we switch only after it settles — switching mid-restoration
            // leaves the IME's input controller without a valid client.
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
    /// apart would re-select the target while it is still activating.
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
    /// after activation. Switching to the target while that restoration is
    /// still in flight leaves the IME's input controller without a valid
    /// client, so Shift stops toggling Chinese/English. Every source change
    /// during the wait restarts the timer, so we only switch after the source
    /// has been quiet for `appSwitchDelay`.
    private func scheduleSettledCorrection() {
        cancelSettledCorrection()
        cancelPendingCorrection()
        // A new app switch starts a fresh correction cycle: reset the retry
        // budget so a retry cancelled by the previous switch cannot make this
        // one give up after a single failed attempt.
        retryCount = 0
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
        /// Display name. Mutable so the picker can disambiguate duplicate names
        /// (Kotoeri exposes "Hiragana" under both Kana and Romaji typing).
        var name: String
        let isEnabled: Bool
        let isSelectable: Bool
        /// `kTISPropertyInputSourceType`: keyboard layout, IME container, IME
        /// mode, palette, …
        let type: String
        /// `kTISPropertyBundleID`. For an IME mode this is the parent IME's ID,
        /// which lets the picker look up the parent's name.
        let bundleID: String

        /// True for real IMEs. Keyboard layouts are excluded from the picker so
        /// the user cannot accidentally pin ABC — that would invert the whole
        /// point of the keeper.
        var isInputMethod: Bool {
            type == (kTISTypeKeyboardInputMethodWithoutModes as String)
                || type == (kTISTypeKeyboardInputMethodModeEnabled as String)
                || type == (kTISTypeKeyboardInputMode as String)
        }
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
                isSelectable: boolProperty(source, kTISPropertyInputSourceIsSelectCapable),
                type: stringProperty(source, kTISPropertyInputSourceType) ?? "",
                bundleID: stringProperty(source, kTISPropertyBundleID) ?? ""
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
            isSelectable: true,
            type: stringProperty(source, kTISPropertyInputSourceType) ?? "",
            bundleID: stringProperty(source, kTISPropertyBundleID) ?? ""
        )
    }

    static func isSogou(_ id: String) -> Bool {
        id.lowercased().contains("sogou")
    }

    /// True when two IDs belong to the same input source family. An IME may
    /// expose a parent source (`com.vendor.ime`) plus one child per input mode
    /// (`com.vendor.ime.wubi`); either may be the current source.
    static func isSameSource(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
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

    /// TIS quirk: an IME *mode* reports `IsEnabled = true` even when its parent
    /// IME is disabled. System Settings only lists the parent, so the parent's
    /// flag is the authoritative one. A mode therefore counts as enabled only
    /// when its parent is enabled too.
    static func isEffectivelyEnabled(_ source: SourceInfo, all: [SourceInfo]) -> Bool {
        guard source.isEnabled else { return false }
        guard source.type == (kTISTypeKeyboardInputMode as String),
              source.bundleID != source.id else { return true }
        guard let parent = all.first(where: { $0.id == source.bundleID }) else { return true }
        return parent.isEnabled
    }

    /// Input sources the user can actually pick: enabled and selectable.
    /// Deduplicated by ID; sorted by display name.
    static func selectableSources() -> [SourceInfo] {
        selectableSources(in: allSources())
    }

    private static func selectableSources(in all: [SourceInfo]) -> [SourceInfo] {
        var seen = Set<String>()
        var result: [SourceInfo] = []
        for source in all where source.isSelectable && isEffectivelyEnabled(source, all: all) {
            guard seen.insert(source.id).inserted else { continue }
            result.append(source)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The picker list: enabled, selectable **input methods only**. Keyboard
    /// layouts (ABC, U.S., …) are filtered out — pinning one would invert the
    /// keeper's purpose. Use `selectableSources()` when you need to know
    /// whether a stored target is still valid.
    ///
    /// Duplicate display names are disambiguated with the parent IME's name:
    /// Kotoeri exposes "Hiragana" under both Kana and Romaji typing, so the
    /// picker shows "Hiragana（Japanese – Kana）" and "Hiragana（Japanese – Romaji）".
    static func selectableInputMethods() -> [SourceInfo] {
        let all = allSources()
        var imes = selectableSources(in: all).filter { $0.isInputMethod }

        let nameCounts = Dictionary(grouping: imes, by: { $0.name }).mapValues(\.count)
        for index in imes.indices where (nameCounts[imes[index].name] ?? 0) > 1 {
            let source = imes[index]
            guard let parent = all.first(where: { $0.id == source.bundleID }),
                  parent.name != source.name else { continue }
            imes[index].name = "\(source.name)（\(parent.name)）"
        }
        return imes
    }

    /// Resolves the target source. When `targetID` is nil, falls back to Sogou
    /// so existing users keep working without re-configuring.
    ///
    /// Prefers the family member that is currently selected (so a user with
    /// both Wubi and Pinyin installed keeps the one they are actually using),
    /// then any selectable mode, then the parent source.
    static func detectStatus(targetID: String?) -> InputSourceStatus {
        let sources = allSources()
        let currentID = currentSource()?.id

        let family: [SourceInfo]
        if let targetID {
            family = sources.filter { isSameSource($0.id, targetID) }
        } else {
            family = sources.filter { isSogou($0.id) }
        }

        if let current = family.first(where: {
            $0.id == currentID && isEffectivelyEnabled($0, all: sources)
        }) {
            return .ready(id: current.id, name: current.name)
        }
        if let ready = family.first(where: {
            $0.isSelectable && isEffectivelyEnabled($0, all: sources)
        }) {
            return .ready(id: ready.id, name: ready.name)
        }
        if let parent = family.first(where: { isEffectivelyEnabled($0, all: sources) }) {
            return .ready(id: parent.id, name: parent.name)
        }
        // The target exists in the system list but none of its modes is
        // enabled — installed, just not switched on.
        if !family.isEmpty {
            return .installedButDisabled(bundleID: targetID ?? family[0].id)
        }
        // Auto mode: a Sogou bundle on disk means "installed but not enabled".
        if targetID == nil, let bundleID = installedSogouBundleID() {
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
