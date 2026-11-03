//
//  LaunchItem.swift
//  jj-type
//
//  User-defined "open this with a hotkey" targets (app / folder / file / URL).
//  The Alfred-style launcher half of the app: one global shortcut, one target.
//

import AppKit

enum LaunchTargetKind: String, Codable, CaseIterable {
    case application
    case folder
    case file
    case url

    var displayName: String {
        switch self {
        case .application: return "应用"
        case .folder: return "文件夹"
        case .file: return "文件"
        case .url: return "网址"
        }
    }
}

struct LaunchItem: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: LaunchTargetKind
    /// Bundle identifier for apps (survives the app being moved), absolute path
    /// for folders/files, the raw string for URLs.
    var target: String
    /// Stable Carbon hotkey id, allocated once at creation: reordering or
    /// deleting other rows can never move a shortcut onto a different item.
    var hotkeySlot: UInt32
    var hotkey: Hotkey?
}

enum LaunchError: LocalizedError {
    case emptyTarget
    case notFound(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTarget:
            return "还没有设置打开目标，请先在设置里选择一个"
        case .notFound(let name):
            return "找不到「\(name)」的目标，可能已被移动或删除，请重新选择"
        case .openFailed(let name):
            return "无法打开「\(name)」，系统拒绝了这次操作"
        }
    }
}

extension LaunchItem {
    /// Bundle URL for apps (bundle id first, stored path as fallback), a plain
    /// file URL for folders/files, and a normalised URL for web targets.
    var resolvedURL: URL? {
        switch kind {
        case .application:
            if !target.hasPrefix("/"),
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
                return url
            }
            guard FileManager.default.fileExists(atPath: target) else { return nil }
            return URL(fileURLWithPath: target, isDirectory: true)
        case .folder, .file:
            guard !target.isEmpty, FileManager.default.fileExists(atPath: target) else { return nil }
            return URL(fileURLWithPath: target, isDirectory: kind == .folder)
        case .url:
            let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            // "example.com" is what people type; the scheme is ours to add.
            if let url = URL(string: raw), url.scheme != nil { return url }
            return URL(string: "https://\(raw)")
        }
    }

    /// Icon for the menu / settings list; nil when the target cannot be resolved.
    var icon: NSImage? {
        guard let url = resolvedURL else { return nil }
        guard kind != .url else {
            return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func open() throws {
        guard !target.isEmpty else { throw LaunchError.emptyTarget }
        guard let url = resolvedURL else { throw LaunchError.notFound(name) }
        guard NSWorkspace.shared.open(url) else { throw LaunchError.openFailed(name) }
    }
}
