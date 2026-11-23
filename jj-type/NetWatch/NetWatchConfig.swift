//
//  NetWatchConfig.swift
//  jj-type
//
//  Configuration for the network watchdog: backup Wi-Fi, VPN check, app
//  relaunch and webhook notification. Persisted in UserDefaults as JSON;
//  the Wi-Fi password lives in the Keychain (see KeychainStore).
//

import Foundation

struct NetWatchConfig: Equatable {
    var enabled: Bool = false

    // MARK: - Backup Wi-Fi

    var backupSSID: String = ""
    /// Empty means "auto-detect the Wi-Fi interface" (usually en0).
    var wifiInterface: String = ""

    // MARK: - Detection

    /// Overseas URL. Reaching it is the real proof that the "road abroad" works
    /// — regardless of HOW that road is provided (OpenVPN, another client, or
    /// a network that is itself a VPN). Any HTTP status counts; only a
    /// transport failure means unreachable.
    var overseasProbeURL: String = "https://www.google.com.hk/"
    /// Domestic URL. Used to tell "the whole internet is down" apart from
    /// "只有出国的路断了" — a distinction the old VPN-status-only check missed.
    var domesticProbeURL: String = "https://ip.cn/"
    var checkIntervalSeconds: Int = 30
    var outageThresholdSeconds: Int = 600
    var switchCooldownSeconds: Int = 300

    // MARK: - VPN

    var vpnTestEnabled: Bool = true
    /// Only the App path matters: the watchdog decides with the overseas LINK
    /// whether the tunnel works, and "connect" is implemented as quit + relaunch
    /// of this app. A VPN service name is deliberately NOT asked for — a VPN may
    /// be provided by another client, or the network itself may be a VPN.
    var vpnAppPath: String = "/Applications/OpenVPN Connect/OpenVPN Connect.app"
    var vpnGraceSeconds: Int = 120
    var vpnWaitSeconds: Int = 60

    // MARK: - App to relaunch after recovery

    var launchAppEnabled: Bool = false
    var launchAppPath: String = ""

    // MARK: - Webhook

    var webhookEnabled: Bool = false
    var webhookURL: String = ""
    var notifyOnSuccess: Bool = true
    var notifyOnFailure: Bool = true

    static let `default` = NetWatchConfig()

    /// Clamp values into sane ranges so a typo in the UI cannot spin the
    /// watchdog into a tight loop or disable the cooldown entirely.
    func sanitized() -> NetWatchConfig {
        var copy = self
        copy.checkIntervalSeconds = min(max(copy.checkIntervalSeconds, 10), 3_600)
        copy.outageThresholdSeconds = min(max(copy.outageThresholdSeconds, 30), 86_400)
        copy.switchCooldownSeconds = min(max(copy.switchCooldownSeconds, 60), 86_400)
        copy.vpnGraceSeconds = min(max(copy.vpnGraceSeconds, 30), 86_400)
        copy.vpnWaitSeconds = min(max(copy.vpnWaitSeconds, 10), 600)
        copy.backupSSID = copy.backupSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.wifiInterface = copy.wifiInterface.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.vpnAppPath = copy.vpnAppPath.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.launchAppPath = copy.launchAppPath.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.webhookURL = copy.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.overseasProbeURL = copy.overseasProbeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.overseasProbeURL.isEmpty {
            copy.overseasProbeURL = NetWatchConfig.default.overseasProbeURL
        }
        copy.domesticProbeURL = copy.domesticProbeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.domesticProbeURL.isEmpty {
            copy.domesticProbeURL = NetWatchConfig.default.domesticProbeURL
        }
        return copy
    }

    /// True when the watchdog has enough information to do its job.
    var isRunnable: Bool {
        enabled && !backupSSID.isEmpty
    }
}

// MARK: - Codable

extension NetWatchConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case backupSSID
        case wifiInterface
        case overseasProbeURL
        case domesticProbeURL
        case checkIntervalSeconds
        case outageThresholdSeconds
        case switchCooldownSeconds
        case vpnTestEnabled
        case vpnAppPath
        case vpnGraceSeconds
        case vpnWaitSeconds
        case launchAppEnabled
        case launchAppPath
        case webhookEnabled
        case webhookURL
        case notifyOnSuccess
        case notifyOnFailure
    }

    /// Decode with per-field fallbacks so a config written by an older build
    /// (missing newer keys) never fails to load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = NetWatchConfig.default
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        backupSSID = try container.decodeIfPresent(String.self, forKey: .backupSSID) ?? fallback.backupSSID
        wifiInterface = try container.decodeIfPresent(String.self, forKey: .wifiInterface) ?? fallback.wifiInterface
        overseasProbeURL = try container.decodeIfPresent(String.self, forKey: .overseasProbeURL) ?? fallback.overseasProbeURL
        domesticProbeURL = try container.decodeIfPresent(String.self, forKey: .domesticProbeURL) ?? fallback.domesticProbeURL
        checkIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .checkIntervalSeconds) ?? fallback.checkIntervalSeconds
        outageThresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .outageThresholdSeconds) ?? fallback.outageThresholdSeconds
        switchCooldownSeconds = try container.decodeIfPresent(Int.self, forKey: .switchCooldownSeconds) ?? fallback.switchCooldownSeconds
        vpnTestEnabled = try container.decodeIfPresent(Bool.self, forKey: .vpnTestEnabled) ?? fallback.vpnTestEnabled
        vpnAppPath = try container.decodeIfPresent(String.self, forKey: .vpnAppPath) ?? fallback.vpnAppPath
        vpnGraceSeconds = try container.decodeIfPresent(Int.self, forKey: .vpnGraceSeconds) ?? fallback.vpnGraceSeconds
        vpnWaitSeconds = try container.decodeIfPresent(Int.self, forKey: .vpnWaitSeconds) ?? fallback.vpnWaitSeconds
        launchAppEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAppEnabled) ?? fallback.launchAppEnabled
        launchAppPath = try container.decodeIfPresent(String.self, forKey: .launchAppPath) ?? fallback.launchAppPath
        webhookEnabled = try container.decodeIfPresent(Bool.self, forKey: .webhookEnabled) ?? fallback.webhookEnabled
        webhookURL = try container.decodeIfPresent(String.self, forKey: .webhookURL) ?? fallback.webhookURL
        notifyOnSuccess = try container.decodeIfPresent(Bool.self, forKey: .notifyOnSuccess) ?? fallback.notifyOnSuccess
        notifyOnFailure = try container.decodeIfPresent(Bool.self, forKey: .notifyOnFailure) ?? fallback.notifyOnFailure
    }
}
