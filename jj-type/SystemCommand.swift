//
//  SystemCommand.swift
//  jj-type
//
//  Alfred-style system commands surfaced by the launcher: lock screen, sleep,
//  restart, shut down, log out, empty trash. They only appear for a NON-empty
//  query that matches the title or an alias — never on the empty list.
//

import AppKit
import CoreGraphics

enum SystemCommand: CaseIterable {
    case lockScreen
    case sleep
    case restart
    case shutdown
    case logout
    case emptyTrash

    var title: String {
        switch self {
        case .lockScreen: return "锁屏"
        case .sleep: return "睡眠"
        case .restart: return "重启"
        case .shutdown: return "关机"
        case .logout: return "注销"
        case .emptyTrash: return "清空废纸篓"
        }
    }

    /// Latin + synonym aliases, joined into one search blob ("lock 锁定屏幕").
    var keywords: String {
        switch self {
        case .lockScreen: return "lock lockscreen 锁定屏幕"
        case .sleep: return "sleep 休眠"
        case .restart: return "restart reboot 重新启动"
        case .shutdown: return "shutdown poweroff power 关闭电脑"
        case .logout: return "logout logoff 登出"
        case .emptyTrash: return "emptytrash trash 清倒废纸篓"
        }
    }

    var detail: String { keywords }

    /// Destructive commands confirm before running; lock/sleep are instant.
    var requiresConfirmation: Bool {
        switch self {
        case .lockScreen, .sleep: return false
        case .restart, .shutdown, .logout, .emptyTrash: return true
        }
    }

    var confirmationHint: String {
        switch self {
        case .restart: return "所有应用会被关闭，然后重新启动。"
        case .shutdown: return "所有应用会被关闭，然后关机。"
        case .logout: return "当前账户的所有应用会被关闭并退出登录。"
        case .emptyTrash: return "废纸篓中的项目将被永久删除。"
        case .lockScreen, .sleep: return ""
        }
    }

    var icon: NSImage? {
        let names: [String]
        switch self {
        case .lockScreen: names = ["lock.display", "lock"]
        case .sleep: names = ["moon.zzz", "moon"]
        case .restart: names = ["arrow.clockwise"]
        case .shutdown: names = ["power"]
        case .logout: names = ["rectangle.portrait.and.arrow.right", "arrow.right.square"]
        case .emptyTrash: names = ["trash"]
        }
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: title) {
                return image
            }
        }
        return nil
    }

    /// Runs the command; throws a Chinese-message error on failure.
    func perform() throws {
        switch self {
        case .lockScreen: Self.lockScreen()
        case .sleep: try Self.runProcess("/usr/bin/pmset", ["sleepnow"])
        case .restart: try Self.runAppleScript("tell application \"System Events\" to restart",
                                               target: "System Events")
        case .shutdown: try Self.runAppleScript("tell application \"System Events\" to shut down",
                                                target: "System Events")
        case .logout: try Self.runAppleScript("tell application \"System Events\" to log out",
                                              target: "System Events")
        case .emptyTrash: try Self.runAppleScript("tell application \"Finder\" to empty trash",
                                                 target: "Finder")
    }
    }

    // MARK: - Private

    /// Locks via the system default ⌃⌘Q shortcut. Posting the synthetic event
    /// needs Accessibility, which the app already requires for its core flows.
    private static func lockScreen() {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// `pmset sleepnow` needs no privileges for a plain user-level sleep.
    private static func runProcess(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            throw SystemCommandError(reason: error.localizedDescription)
        }
    }

    /// NSAppleScript must run on the main thread; every caller already is on it.
    /// System Events / Finder automation needs a one-time TCC grant (Automation
    /// pane); a missing grant is reported as a fixable authorization failure,
    /// not a raw Apple error.
    private static func runAppleScript(_ source: String, target: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw SystemCommandError(reason: "脚本创建失败")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return }
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "未知错误"
        let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        // -1743 = errAEEventNotPermitted.
        if number == -1743 {
            throw SystemCommandError(reason: target, isAuthorizationFailure: true)
        }
        throw SystemCommandError(reason: message)
    }
}

/// Chinese-message wrapper for command failures; authorization failures get
/// their own flag so AppDelegate can offer the settings pane.
struct SystemCommandError: LocalizedError {
    let reason: String
    var isAuthorizationFailure = false

    var errorDescription: String? {
        isAuthorizationFailure
            ? "缺少「自动化」权限（\(reason)）"
            : "执行失败：\(reason)"
    }
}
