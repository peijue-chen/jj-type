//
//  SettingsStore.swift
//  jj-type
//
//  Persists provider list, active provider and hotkeys in UserDefaults.
//  API keys are delegated to KeychainStore.
//

import Foundation

struct ProviderConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var baseURL: String
    var model: String
}

enum ProviderError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "未找到该服务配置，可能已被删除"
        }
    }
}

final class SettingsStore {
    enum Key {
        static let providers = "jjtype.providers"
        static let activeProviderId = "jjtype.activeProviderId"
        static let hotkeyTranslate = "jjtype.hotkey.translate"
        static let hotkeyCorrect = "jjtype.hotkey.correct"
        static let hotkeyCapture = "jjtype.hotkey.capture"
        static let hotkeyLauncher = "jjtype.hotkey.launcher"
        static let hotkeyClipboard = "jjtype.hotkey.clipboard"
        static let hotkeyColorPicker = "jjtype.hotkey.colorPicker"
        static let hotkeyQRCode = "jjtype.hotkey.qrCode"
        static let hotkeyDevTool = "jjtype.hotkey.devTool"
        static let hotkeySelectionBar = "jjtype.hotkey.selectionBar"
        static let colorHistory = "jjtype.colorPicker.history"
        static let captureSaveDirectory = "jjtype.capture.saveDirectory"
        static let captureFormat = "jjtype.capture.format"
        static let accessibilityGuided = "jjtype.guided.accessibility"
        static let launchItems = "jjtype.launchItems"
        static let preferredTerminal = "jjtype.terminal.preferred"
        static let aiActions = "jjtype.aiActions"
        static let selectionBar = "jjtype.selectionBar.enabled"
    }

    /// Fired whenever the provider list or active provider changes (menu rebuild).
    var onProvidersChanged: (() -> Void)?
    /// Fired whenever a hotkey binding changes (HotkeyManager re-registration).
    var onHotkeyChanged: (() -> Void)?
    /// Fired when a launch item is added, edited or removed (menu + hotkeys).
    var onLaunchItemsChanged: (() -> Void)?

    private let defaults: UserDefaults

    private(set) var providers: [ProviderConfig]
    private(set) var activeProviderId: UUID?
    private(set) var launchItems: [LaunchItem]
    /// User-defined AI quick actions (shown after the built-ins).
    private(set) var aiActions: [QuickAction]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.providers),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            providers = decoded
        } else {
            providers = []
        }
        activeProviderId = defaults.string(forKey: Key.activeProviderId).flatMap(UUID.init(uuidString:))
        // Keep the invariant: active id must reference an existing provider.
        if let id = activeProviderId, !providers.contains(where: { $0.id == id }) {
            activeProviderId = nil
        }
        if let data = defaults.data(forKey: Key.launchItems),
           let decoded = try? JSONDecoder().decode([LaunchItem].self, from: data) {
            launchItems = decoded
        } else {
            launchItems = []
        }
        if let data = defaults.data(forKey: Key.aiActions),
           let decoded = try? JSONDecoder().decode([QuickAction].self, from: data) {
            aiActions = decoded
        } else {
            aiActions = []
        }
        seedBuiltInActions()
    }

    /// The built-ins (翻译 / 纠正 / 润色 / 改写) live IN the persisted list so
    /// their prompts are user-editable; missing ones (first run OR upgrade from
    /// an earlier built-in set) are slotted into their CATALOG position — a
    /// newly added built-in must not jump to the front on upgrade. Edits are
    /// never overwritten — seeding keeps the stored prompt when the id exists.
    private func seedBuiltInActions() {
        let known = Set(aiActions.map(\.id))
        guard QuickActionCatalog.builtIns.contains(where: { !known.contains($0.id) }) else { return }
        let stored = Dictionary(aiActions.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let customs = aiActions.filter { !QuickActionCatalog.builtInIds.contains($0.id) }
        aiActions = QuickActionCatalog.builtIns.map { stored[$0.id] ?? $0 } + customs
        persistAIActions()
    }

    /// PopClip-style selection bar (utils-7). Defaults ON.
    var selectionBarEnabled: Bool {
        get {
            defaults.object(forKey: Key.selectionBar) == nil
                ? true
                : defaults.bool(forKey: Key.selectionBar)
        }
        set { defaults.set(newValue, forKey: Key.selectionBar) }
    }

    var activeProvider: ProviderConfig? {
        providers.first { $0.id == activeProviderId }
    }

    var translateHotkey: Hotkey {
        get { hotkey(forKey: Key.hotkeyTranslate) ?? .defaultTranslate }
        set { saveHotkey(newValue, forKey: Key.hotkeyTranslate); onHotkeyChanged?() }
    }

    var correctHotkey: Hotkey {
        get { hotkey(forKey: Key.hotkeyCorrect) ?? .defaultCorrect }
        set { saveHotkey(newValue, forKey: Key.hotkeyCorrect); onHotkeyChanged?() }
    }

    var captureHotkey: Hotkey {
        get { hotkey(forKey: Key.hotkeyCapture) ?? .defaultCapture }
        set { saveHotkey(newValue, forKey: Key.hotkeyCapture); onHotkeyChanged?() }
    }

    var launcherHotkey: Hotkey {
        get { hotkey(forKey: Key.hotkeyLauncher) ?? .defaultLauncher }
        set { saveHotkey(newValue, forKey: Key.hotkeyLauncher); onHotkeyChanged?() }
    }

    var clipboardHotkey: Hotkey {
        get { hotkey(forKey: Key.hotkeyClipboard) ?? .defaultClipboardHistory }
        set { saveHotkey(newValue, forKey: Key.hotkeyClipboard); onHotkeyChanged?() }
    }

    var colorPickerHotkey: Hotkey {
        get { hotkey(forKey: Key.hotkeyColorPicker) ?? .defaultColorPicker }
        set { saveHotkey(newValue, forKey: Key.hotkeyColorPicker); onHotkeyChanged?() }
    }

    var qrCodeHotkey: Hotkey {
        get { hotkey(forKey: Key.hotkeyQRCode) ?? .defaultQRCode }
        set { saveHotkey(newValue, forKey: Key.hotkeyQRCode); onHotkeyChanged?() }
    }

    var devToolHotkey: Hotkey {
        get { hotkey(forKey: Key.hotkeyDevTool) ?? .defaultDevTool }
        set { saveHotkey(newValue, forKey: Key.hotkeyDevTool); onHotkeyChanged?() }
    }

    /// Summons the selection action bar on demand (works even when the
    /// automatic bar is disabled).
    var selectionBarHotkey: Hotkey {
        get { hotkey(forKey: Key.hotkeySelectionBar) ?? .defaultSelectionBar }
        set { saveHotkey(newValue, forKey: Key.hotkeySelectionBar); onHotkeyChanged?() }
    }

    /// Recent picked colors (as copied strings), newest first, capped at 12.
    var colorHistory: [String] {
        get { defaults.stringArray(forKey: Key.colorHistory) ?? [] }
        set { defaults.set(Array(newValue.prefix(12)), forKey: Key.colorHistory) }
    }

    func recordColorHistory(_ value: String) {
        var history = colorHistory.filter { $0 != value }
        history.insert(value, at: 0)
        colorHistory = history
    }

    // MARK: - Screenshot settings

    /// Defaults to ~/Pictures/JJType; created lazily when the first shot is saved.
    var captureSaveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Key.captureSaveDirectory), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return Self.defaultCaptureDirectory
        }
        set {
            guard newValue.path != captureSaveDirectory.path else { return }
            defaults.set(newValue.path, forKey: Key.captureSaveDirectory)
        }
    }

    var captureFormat: CaptureFormat {
        get {
            guard let raw = defaults.string(forKey: Key.captureFormat),
                  let format = CaptureFormat(rawValue: raw) else { return .png }
            return format
        }
        set {
            guard newValue != captureFormat else { return }
            defaults.set(newValue.rawValue, forKey: Key.captureFormat)
        }
    }

    private static var defaultCaptureDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return pictures.appendingPathComponent("JJType", isDirectory: true)
    }

    // MARK: - Providers

    /// Keychain first, then persist — on Keychain failure nothing is stored.
    /// Throws KeychainError (with OSStatus) so callers can surface the real code.
    func addProvider(_ config: ProviderConfig, apiKey: String) throws {
        try KeychainStore.saveAPIKey(apiKey, for: config.id)
        providers.append(config)
        if activeProviderId == nil { activeProviderId = config.id }
        persistProviders()
    }

    /// apiKey nil keeps the existing Keychain entry unchanged.
    /// Throws ProviderError.notFound or KeychainError (with OSStatus).
    func updateProvider(_ config: ProviderConfig, apiKey: String?) throws {
        guard let index = providers.firstIndex(where: { $0.id == config.id }) else {
            throw ProviderError.notFound
        }
        if let apiKey {
            try KeychainStore.saveAPIKey(apiKey, for: config.id)
        }
        providers[index] = config
        persistProviders()
    }

    func deleteProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        KeychainStore.deleteAPIKey(for: id)
        // Plan §8: deleting the active provider CLEARS the active selection
        // (the user re-picks via menu or settings) instead of auto-filling.
        if activeProviderId == id { activeProviderId = nil }
        persistProviders()
    }

    func setActiveProvider(id: UUID) {
        guard providers.contains(where: { $0.id == id }) else { return }
        activeProviderId = id
        defaults.set(id.uuidString, forKey: Key.activeProviderId)
        onProvidersChanged?()
    }

    // MARK: - Launch items

    /// First free hotkey slot; slots are 100...999 so they never collide with the
    /// built-in actions. When the range is exhausted the numbering continues past
    /// it — reusing `upperBound` would give two items the same slot (and the
    /// hotkey would only ever reach the first one).
    var nextLaunchHotkeySlot: UInt32 {
        let used = Set(launchItems.map(\.hotkeySlot))
        if let free = HotkeyManager.launchItemSlotRange.first(where: { !used.contains($0) }) {
            return free
        }
        return (used.max() ?? HotkeyManager.launchItemSlotRange.upperBound) + 1
    }

    func addLaunchItem(_ item: LaunchItem) {
        launchItems.append(item)
        persistLaunchItems()
    }

    /// Replaces the stored item with the same id; ignored when it was removed
    /// while the editor was open.
    func updateLaunchItem(_ item: LaunchItem) {
        guard let index = launchItems.firstIndex(where: { $0.id == item.id }) else { return }
        guard launchItems[index] != item else { return }
        launchItems[index] = item
        persistLaunchItems()
    }

    func deleteLaunchItem(id: UUID) {
        let before = launchItems.count
        launchItems.removeAll { $0.id == id }
        guard launchItems.count != before else { return }
        persistLaunchItems()
    }

    // MARK: - AI quick actions

    /// Custom quick actions; the panel re-reads them on every show, so no
    /// change callback is needed.
    func addAIAction(_ action: QuickAction) {
        aiActions.append(action)
        persistAIActions()
    }

    func updateAIAction(_ action: QuickAction) {
        guard let index = aiActions.firstIndex(where: { $0.id == action.id }) else { return }
        guard aiActions[index] != action else { return }
        aiActions[index] = action
        persistAIActions()
    }

    func deleteAIAction(id: UUID) {
        // Built-ins are editable but never deletable.
        guard !QuickActionCatalog.builtInIds.contains(id) else { return }
        let before = aiActions.count
        aiActions.removeAll { $0.id == id }
        guard aiActions.count != before else { return }
        persistAIActions()
    }

    private func persistAIActions() {
        if let data = try? JSONEncoder().encode(aiActions) {
            defaults.set(data, forKey: Key.aiActions)
        }
    }

    // MARK: - Finder toolbar terminal

    /// Preferred terminal bundle id for the Finder-toolbar "open terminal"
    /// action; nil = auto (iTerm2 when installed, else Terminal.app). Invalid
    /// or uninstalled values fall back at use time, so nothing is ever broken.
    var preferredTerminalRawValue: String? {
        get { defaults.string(forKey: Key.preferredTerminal) }
        set {
            guard newValue != preferredTerminalRawValue else { return }
            defaults.set(newValue, forKey: Key.preferredTerminal)
        }
    }

    // MARK: - First-run guidance flag

    var accessibilityGuidedShown: Bool {
        get { defaults.bool(forKey: Key.accessibilityGuided) }
        set { defaults.set(newValue, forKey: Key.accessibilityGuided) }
    }

    // MARK: - Private

    private func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Key.providers)
        }
        defaults.set(activeProviderId?.uuidString, forKey: Key.activeProviderId)
        onProvidersChanged?()
    }

    private func persistLaunchItems() {
        if let data = try? JSONEncoder().encode(launchItems) {
            defaults.set(data, forKey: Key.launchItems)
        }
        onLaunchItemsChanged?()
    }

    private func hotkey(forKey key: String) -> Hotkey? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    private func saveHotkey(_ hotkey: Hotkey, forKey key: String) {
        if let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: key)
        }
    }
}
