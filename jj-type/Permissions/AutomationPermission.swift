//
//  AutomationPermission.swift
//  jj-type
//
//  Automation (Apple Events) TCC probe + Chinese guidance window. Unlike
//  Accessibility / Screen Recording there is NO preflight API: the only way
//  to learn the state is to send a benign Apple event, and the first probe
//  for an undecided target IS the request (it shows the native prompt).
//  Targets: Finder (empty trash, Finder-toolbar terminal) and System Events
//  (restart / shutdown / logout).
//

import AppKit

enum AutomationTarget: String, CaseIterable {
    case finder = "Finder"
    case systemEvents = "System Events"

    var displayName: String { rawValue }

    /// What the app needs this target for (shown in the guide rows).
    var purpose: String {
        switch self {
        case .finder: return "Finder 工具栏打开终端、清空废纸篓"
        case .systemEvents: return "重启 / 关机 / 注销"
        }
    }
}

enum AutomationPermission {
    /// Sends a benign probe event (`get name`; both targets are always
    /// running so the round-trip is fast). True = the event went through.
    /// First call for a target without a TCC decision shows the system prompt
    /// ("JJType" 想控制 …) and fails — that is the REQUEST step, not an
    /// error: the user allows, then verifies again.
    @discardableResult
    static func verify(_ target: AutomationTarget) -> Bool {
        let source = "tell application \"\(target.rawValue)\" to get name"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    static func openSystemSettings() {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: legacy) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Supplementary Chinese guidance window. There is no silent auto-skip: an
/// undecided probe would prompt, so the window always opens and the user
/// drives verification with the 验证权限 button.
final class AutomationGuideWindowController: NSWindowController {
    static let shared = AutomationGuideWindowController()

    private var statusLabels: [AutomationTarget: NSTextField] = [:]

    convenience init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "需要自动化权限"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentViewController = NSViewController()
        window.contentViewController?.view = content
        buildLayout(in: content)
    }

    func showIfNeeded(force: Bool = false) {
        // Apple Events cannot be preflighted silently (any check is a live
        // probe that may prompt), so unlike the other guides there is no
        // auto-skip when already granted.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildLayout(in view: NSView) {
        let explanation = NSTextField(wrappingLabelWithString:
            "jj-type 需要「自动化」权限才能：\n"
            + "• 在 Finder 工具栏点击打开终端、清空废纸篓（控制 Finder）\n"
            + "• 重启 / 关机 / 注销（控制 System Events）\n\n"
            + "1. 点击「验证权限」：首次会弹出系统询问「JJType」想控制 …，点「允许」。\n"
            + "2. 若未弹窗或曾点过「拒绝」：打开 系统设置 → 隐私与安全性 → 自动化，"
            + "找到 JJType，打开对应开关（列表条目只在首次尝试后才出现）。\n\n"
            + "注意：从 Xcode 调试运行时，授权记录会挂在 Xcode 名下（列表里是 Xcode "
            + "而不是 JJType）；独立运行的 JJType 才会有自己的条目。")
        explanation.alignment = .left

        var rows: [NSView] = [explanation]
        for target in AutomationTarget.allCases {
            let name = NSTextField(labelWithString: "控制 \(target.displayName) — \(target.purpose)：")
            name.font = .systemFont(ofSize: 12)
            let status = NSTextField(labelWithString: "未验证")
            status.font = .systemFont(ofSize: 12)
            status.textColor = .secondaryLabelColor
            statusLabels[target] = status
            let row = NSStackView(views: [name, status])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            rows.append(row)
        }

        let settingsButton = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .rounded
        let verifyButton = NSButton(title: "验证权限", target: self, action: #selector(verify))
        verifyButton.bezelStyle = .rounded
        verifyButton.keyEquivalent = "\r"

        let stack = NSStackView(views: rows + [
            NSStackView(views: [settingsButton, verifyButton]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func openSettings() {
        AutomationPermission.openSystemSettings()
    }

    @objc private func verify() {
        for target in AutomationTarget.allCases {
            guard let label = statusLabels[target] else { continue }
            if AutomationPermission.verify(target) {
                label.stringValue = "✓ 已授权"
                label.textColor = .systemGreen
            } else {
                label.stringValue = "✗ 未授权（若刚弹出系统询问，点允许后再次验证）"
                label.textColor = .systemRed
            }
        }
    }
}
