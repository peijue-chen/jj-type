//
//  LaunchAtLoginService.swift
//  jj-type
//
//  Login-item (launch at login) support backed by SMAppService.mainApp.
//  The system status is the single source of truth — a UserDefaults mirror
//  would drift from what 系统设置 → 通用 → 登录项 shows as soon as the user
//  flips the switch there, and the settings checkbox would lie.
//

import Foundation
import ServiceManagement

enum LaunchAtLoginService {

    /// The four states the settings page has to render differently.
    enum State: Equatable {
        /// Registered and active — the app starts at login.
        case enabled
        /// Never registered, or unregistered by the user from our UI.
        case notRegistered
        /// Registered but switched OFF in System Settings → 登录项; only the
        /// user can turn it back on there.
        case requiresApproval
        /// The system cannot resolve the login item (unsupported / broken
        /// bundle registration).
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        // `.notFound` is what a NEVER-registered app reports on macOS 26
        // (verified live: a fresh copy returns .notFound, register() then
        // succeeds and the status flips to .enabled; after unregister() it
        // reports .notRegistered). Treating it as "unsupported" showed a
        // bogus 「当前系统不支持登录项」 on first run — it is simply "off".
        case .notFound: return .notRegistered
        @unknown default: return .unavailable
        }
    }

    /// True when the bundle lives in /Applications or ~/Applications.
    /// The login item records the CURRENT bundle path, so a copy running from
    /// a build folder would be the one launched at login — the settings page
    /// warns about that instead of silently registering the wrong copy.
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Registers / unregisters the login item. Throws the underlying
    /// SMAppService error (unsigned bundle, translocated path, …) so the
    /// caller can surface it verbatim instead of failing silently.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    /// Deep link to 系统设置 → 通用 → 登录项 (the only place a
    /// `.requiresApproval` item can be re-enabled).
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
