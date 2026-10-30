//
//  AccessibilityPermission.swift
//  jj-type
//
//  Accessibility trust check, native permission prompt (mainstream-app
//  behavior via AXIsProcessTrustedWithOptions) and the guidance window.
//

import AppKit

enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system's native permission dialog (with a direct
    /// "Open System Settings" entry) when the app is not yet trusted.
    /// Repeated calls are safe — macOS only shows the dialog once per app
    /// until the user interacts with it. Returns the current trust state.
    @discardableResult
    static func requestTrust() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        // macOS 13+ modern pane URL first; fall back to the legacy pane path.
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: legacy) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Supplementary Chinese guidance window (the native prompt is primary).
final class AccessibilityGuideWindowController: NSWindowController {
    static let shared = AccessibilityGuideWindowController()

    private let statusLabel = NSTextField(labelWithString: "")

    convenience init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "需要辅助功能权限"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentViewController = NSViewController()
        window.contentViewController?.view = content
        buildLayout(in: content)
    }

    func showIfNeeded(force: Bool = false) {
        if !force && AccessibilityPermission.isGranted { return }
        // LSUIElement apps never auto-activate; bring ourselves forward explicitly.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refreshStatus()
    }

    private func buildLayout(in view: NSView) {
        let explanation = NSTextField(wrappingLabelWithString:
            "jj-type 需要辅助功能权限才能：\n• 注册全局快捷键\n• 模拟 ⌘C 抓取选中文本\n• 模拟 ⌘V 将纠正结果写回原文位置\n\n若未弹出系统授权提示，请在 系统设置 → 隐私与安全性 → 辅助功能 中手动勾选 jj-type，然后返回点击「重新检测」。")
        explanation.alignment = .left

        let settingsButton = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .rounded
        let recheckButton = NSButton(title: "重新检测", target: self, action: #selector(recheck))
        recheckButton.bezelStyle = .rounded
        recheckButton.keyEquivalent = "\r"

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        let stack = NSStackView(views: [explanation, statusLabel,
                                        NSStackView(views: [settingsButton, recheckButton])])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func refreshStatus() {
        statusLabel.stringValue = AccessibilityPermission.isGranted
            ? "✓ 已获得权限"
            : "尚未授权"
    }

    @objc private func openSettings() {
        AccessibilityPermission.openSystemSettings()
    }

    @objc private func recheck() {
        refreshStatus()
    }
}
