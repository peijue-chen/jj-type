//
//  KeychainStore.swift
//  jj-type
//
//  Thin wrapper over the Security framework for provider API keys.
//  Keys are stored ONLY here — never in UserDefaults and never in the repo.
//

import Foundation
import Security

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "API Key 保存失败（钥匙串错误 \(status)），请重试"
        }
    }
}

enum KeychainStore {
    static let service = "com.aigens.jj-type.provider"
    /// Separate service so Wi-Fi credentials never mix with AI provider keys.
    static let netWatchService = "com.aigens.jj-type.netwatch"

    private static func baseQuery(for providerID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
        ]
    }

    private static func netWatchQuery(ssid: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: netWatchService,
            kSecAttrAccount as String: ssid,
        ]
    }

    /// Saves (insert or update) the API key for a provider. Throws on Keychain failure
    /// so callers can surface the error instead of silently dropping the key.
    static func saveAPIKey(_ key: String, for providerID: UUID) throws {
        let data = Data(key.utf8)
        let query = baseQuery(for: providerID)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // Try update first; insert when the item does not exist yet.
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
    }

    /// Loads the API key for a provider, or nil when absent/locked.
    static func loadAPIKey(for providerID: UUID) -> String? {
        var query = baseQuery(for: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the API key for a provider. Missing items are not an error.
    static func deleteAPIKey(for providerID: UUID) {
        SecItemDelete(baseQuery(for: providerID) as CFDictionary)
    }

    // MARK: - NetWatch Wi-Fi password

    /// Saves (insert or update) the password for a backup Wi-Fi SSID.
    /// Returns false when the Keychain rejects the write.
    @discardableResult
    static func saveWiFiPassword(_ password: String, ssid: String) -> Bool {
        guard !ssid.isEmpty else { return false }
        let data = Data(password.utf8)
        let query = netWatchQuery(ssid: ssid)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func loadWiFiPassword(ssid: String) -> String? {
        guard !ssid.isEmpty else { return nil }
        var query = netWatchQuery(ssid: ssid)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteWiFiPassword(ssid: String) {
        guard !ssid.isEmpty else { return }
        SecItemDelete(netWatchQuery(ssid: ssid) as CFDictionary)
    }
}
