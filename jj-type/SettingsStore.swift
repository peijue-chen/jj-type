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
        static let accessibilityGuided = "jjtype.guided.accessibility"
    }

    /// Fired whenever the provider list or active provider changes (menu rebuild).
    var onProvidersChanged: (() -> Void)?
    /// Fired whenever a hotkey binding changes (HotkeyManager re-registration).
    var onHotkeyChanged: (() -> Void)?

    private let defaults: UserDefaults

    private(set) var providers: [ProviderConfig]
    private(set) var activeProviderId: UUID?

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
