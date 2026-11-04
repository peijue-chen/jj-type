//
//  CaptureToast.swift
//  jj-type
//
//  Transient HUD feedback for screenshot actions ("已识别 12 行文字，已复制到
//  剪贴板"). One reused panel: it never takes focus, never intercepts clicks and
//  dismisses itself, so it can be shown after the overlay is already gone.
//

import AppKit
import CoreGraphics

@MainActor
final class CaptureToast {
    static let shared = CaptureToast()

    private var panel: NSPanel?
    private var container: NSVisualEffectView?
    private var iconView: NSImageView?
    private var label: NSTextField?
    private var dismissTask: Task<Void, Never>?

    private let iconSide: CGFloat = 15
    private let padding: CGFloat = 13
    private let spacing: CGFloat = 8
    private let maxWidth: CGFloat = 440
    private let height: CGFloat = 36

    private init() {}

    /// Shows `message` near the bottom of the screen that holds the pointer.
    func show(_ message: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.8) {
        let panel = panel ?? makePanel()
        iconView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView?.contentTintColor = .labelColor
        label?.stringValue = message
        layout(panel)

        dismissTask?.cancel()
        if panel.isVisible {
            // Replacing a message ("正在识别…" → "已识别 N 行"): no fade flash.
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        dismissTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0.4, duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: height),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        created.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 4)
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        created.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = height / 2
        effect.layer?.masksToBounds = true
        created.contentView = effect
        container = effect

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(icon)
        iconView = icon

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        effect.addSubview(text)
        label = text

        panel = created
        return created
    }

    private func layout(_ panel: NSPanel) {
        guard let container, let label, let icon = iconView else { return }
        let textWidth = label.intrinsicContentSize.width
        let width = padding * 2 + iconSide + spacing + min(maxWidth, max(40, textWidth))
        panel.setContentSize(NSSize(width: width, height: height))
        container.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        icon.frame = NSRect(x: padding,
                            y: (height - iconSide) / 2,
                            width: iconSide,
                            height: iconSide)
        label.frame = NSRect(x: padding + iconSide + spacing,
                             y: (height - 18) / 2,
                             width: width - padding * 2 - iconSide - spacing,
                             height: 18)
        position(panel, size: NSSize(width: width, height: height))
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: size)
        let x = min(max(screen.midX - size.width / 2, screen.minX + 8),
                    max(screen.minX + 8, screen.maxX - size.width - 8))
        let y = screen.minY + 96
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
