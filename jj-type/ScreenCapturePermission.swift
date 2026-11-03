//
//  ScreenCapturePermission.swift
//  jj-type
//
//  Screen Recording (TCC) check, native request, relaunch helper and the
//  Chinese guidance window. Screen Recording is separate from Accessibility.
//

import AppKit
import CoreGraphics

enum ScreenCapturePermission {
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt. macOS shows it once per app until the user
    /// interacts with it, so repeat calls are safe.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: legacy) {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS only applies a newly granted Screen Recording permission at process
    /// launch, so a fresh grant needs a relaunch before captures stop being black.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }
}

/// Supplementary Chinese guidance window (the native prompt is primary).
final class ScreenCaptureGuideWindowController: NSWindowController {
    static let shared = ScreenCaptureGuideWindowController()

    private let statusLabel = NSTextField(labelWithString: "")

    convenience init() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "需要屏幕录制权限"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentViewController = NSViewController()
        window.contentViewController?.view = content
        buildLayout(in: content)
    }

    func showIfNeeded(force: Bool = false) {
        if !force && ScreenCapturePermission.isGranted { return }
        // LSUIElement apps never auto-activate; bring ourselves forward explicitly.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refreshStatus()
    }

    private func buildLayout(in view: NSView) {
        let explanation = NSTextField(wrappingLabelWithString:
            "jj-type 需要「屏幕录制」权限才能截屏：\n\n"
            + "1. 点击「打开系统设置」，在 隐私与安全性 → 屏幕录制 中勾选 jj-type。\n"
            + "2. 授权后必须重启 JJType 才会真正生效（这是 macOS 的限制，否则截图会是黑的或失败）。\n\n"
            + "该权限与「辅助功能」是两套独立授权，互不影响。")
        explanation.alignment = .left

        let settingsButton = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .rounded
        let relaunchButton = NSButton(title: "已授权，重启 JJType", target: self, action: #selector(relaunch))
        relaunchButton.bezelStyle = .rounded
        let recheckButton = NSButton(title: "重新检测", target: self, action: #selector(recheck))
        recheckButton.bezelStyle = .rounded
        recheckButton.keyEquivalent = "\r"

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        let buttons = NSStackView(views: [settingsButton, relaunchButton, recheckButton])
        buttons.spacing = 10

        let stack = NSStackView(views: [explanation, statusLabel, buttons])
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
        statusLabel.stringValue = ScreenCapturePermission.isGranted
            ? "✓ 已获得权限（若截图仍是黑图，请重启 JJType）"
            : "尚未授权"
    }

    @objc private func openSettings() {
        ScreenCapturePermission.openSystemSettings()
    }

    @objc private func relaunch() {
        ScreenCapturePermission.relaunch()
    }

    @objc private func recheck() {
        refreshStatus()
    }
}
