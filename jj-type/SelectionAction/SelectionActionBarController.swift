//
//  SelectionActionBarController.swift
//  jj-type
//
//  PopClip-style selection action bar (utils-7): a drag-selection (mouseUp
//  far enough from its mouseDown) triggers an AX-only selection read; when
//  text is selected a small non-activating chip bar appears under the cursor
//  — 复制 / every AI quick action / 二维码. Clicking anywhere outside (or a
//  new selection, or Esc) dismisses it instantly. No polling, no clipboard
//  side effects on detection.
//

import AppKit
import Carbon.HIToolbox
import ObjectiveC

final class SelectionActionBarController {
    static let shared = SelectionActionBarController()

    /// Chip tap outcomes, executed by AppDelegate (owner of the AI pipeline).
    var onQuickAction: ((QuickAction, String) -> Void)?
    var onGenerateQR: ((String) -> Void)?

    /// Called with the current action list whenever the bar is (re)built —
    /// the owner returns live settings, so edits apply to the next show.
    var actionsProvider: (() -> [QuickAction])?

    private let panel: NSPanel
    private let chipsRow = NSStackView()
    /// Full capture chain (AX-first + synthetic-⌘C fallback): browsers and
    /// Electron apps rarely expose kAXSelectedTextAttribute, so the AX-only
    /// peek only ever worked in apps like Xcode (the "只在 Xcode 生效" bug).
    private let textCapture = TextCaptureService()

    private var trackingMonitors: [Any] = []
    private var dismissMonitors: [Any] = []
    private var enabled = false
    private var mouseDownLocation: NSPoint?
    /// Below this drag distance a mouseUp is a click, not a selection.
    private static let dragThreshold: CGFloat = 12

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        panel.contentView = background

        chipsRow.orientation = .horizontal
        chipsRow.spacing = 6
        chipsRow.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        chipsRow.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(chipsRow)
        NSLayoutConstraint.activate([
            chipsRow.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            chipsRow.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            chipsRow.topAnchor.constraint(equalTo: background.topAnchor),
            chipsRow.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    // MARK: - Enable / disable (settings-driven)

    /// Installs or removes the global tracking monitors. Requires the
    /// Accessibility grant (global mouse monitors + AX read); the owner gates.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            installTrackingMonitors()
        } else {
            removeTrackingMonitors()
            dismiss()
        }
    }

    private func installTrackingMonitors() {
        guard trackingMonitors.isEmpty else { return }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // NSEvent.mouseLocation is the ONLY reliable screen coordinate in a
            // global monitor — event.locationInWindow is window-relative (or
            // undefined for other apps' events) and broke the drag-distance
            // check (the "划词没有生效" bug).
            MainActor.assumeIsolated { self?.mouseDownLocation = NSEvent.mouseLocation }
        }
        // mouseUp on OUR windows never reaches the global monitor.
        let localDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.mouseDownLocation = NSEvent.mouseLocation
                self?.handlePossibleDismissClick()
            }
            return event
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSelectionCandidate(at: NSEvent.mouseLocation) }
        }
        trackingMonitors = [down, localDown, up].compactMap { $0 }
    }

    private func removeTrackingMonitors() {
        trackingMonitors.forEach { NSEvent.removeMonitor($0) }
        trackingMonitors = []
    }

    // MARK: - Selection detection

    private func handleSelectionCandidate(at location: NSPoint) {
        // A click is not a selection — skip the capture round-trip entirely.
        guard let start = mouseDownLocation else { return }
        let distance = hypot(location.x - start.x, location.y - start.y)
        guard distance >= Self.dragThreshold else { return }
        NSLog("[JJType][SelectionBar] drag %.0fpt at (%.0f, %.0f) — reading selection",
              distance, location.x, location.y)
        // A tiny settle beat after mouseUp: apps that need the ⌘C fallback
        // are often still finalizing their selection highlight, and an
        // instant ⌘C copies the PREVIOUS clipboard content (the intermittent
        // wrong-text bug).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.enabled else { return }
            // AX-first with the synthetic-⌘C fallback (the SAME chain ⌥E
            // uses) — apps without AX selected-text support still work.
            self.textCapture.captureSelectedText { [weak self] result in
                guard let self, self.enabled else { return }
                switch result {
                case .success(let text):
                    NSLog("[JJType][SelectionBar] selection %d chars — showing bar", text.count)
                    self.show(text: text, at: location)
                case .failure:
                    NSLog("[JJType][SelectionBar] no selection — dismissed")
                    self.dismiss()
                }
            }
        }
    }

    // MARK: - Bar presentation

    private func show(text: String, at location: NSPoint) {
        rebuildChips(for: text)
        positionPanel(at: location)
        installDismissMonitors()
        panel.orderFrontRegardless()
    }

    func dismiss() {
        removeDismissMonitors()
        panel.orderOut(nil)
    }

    private var isVisible: Bool { panel.isVisible }

    /// Chips: every quick action, then 二维码 (复制 removed 2026-11-05 — the
    /// selection is already IN the clipboard of the source app, and the chip
    /// crowded the bar). Every chip dismisses the bar BEFORE running its
    /// action (PopClip behavior).
    private func rebuildChips(for text: String) {
        chipsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for action in actionsProvider?() ?? [] {
            let actionChip = chip(title: action.name) { [weak self] in
                self?.dismiss()
                self?.onQuickAction?(action, text)
            }
            chipsRow.addArrangedSubview(actionChip)
        }

        let qrChip = chip(title: "二维码") { [weak self] in
            self?.dismiss()
            self?.onGenerateQR?(text)
        }
        chipsRow.addArrangedSubview(qrChip)

        panel.setContentSize(NSSize(width: max(200, chipsRow.fittingSize.width), height: 40))
    }

    private func chip(title: String, handler: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.onAction = { _ in handler() }
        return button
    }

    /// Below the selection end point; flips above the cursor near edges.
    private func positionPanel(at location: NSPoint) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = NSPoint(x: location.x - size.width / 2, y: location.y - size.height - 14)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        if origin.y < visible.minY + 8 {
            origin.y = location.y + 18
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Dismissal (click outside / Esc)

    private func installDismissMonitors() {
        guard dismissMonitors.isEmpty else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.handlePossibleDismissClick() }
        }
        let key = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) { self?.dismiss() }
            }
        }
        let localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) { self?.dismiss() }
            }
            return event
        }
        dismissMonitors = [global, key, localKey].compactMap { $0 }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach { NSEvent.removeMonitor($0) }
        dismissMonitors = []
    }

    private func handlePossibleDismissClick() {
        guard isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        dismiss()
    }
}

/// Compact target/action-through-closure extension (keeps chip wiring local).
private extension NSButton {
    typealias ActionHandler = (NSButton) -> Void
    private struct AssociatedKey {
        static var handler = "jjtype.actionHandler"
    }

    var onAction: ActionHandler? {
        get { objc_getAssociatedObject(self, &AssociatedKey.handler) as? ActionHandler }
        set {
            objc_setAssociatedObject(self, &AssociatedKey.handler, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            target = self
            action = #selector(invokeAssociatedHandler)
        }
    }

    @objc private func invokeAssociatedHandler() {
        onAction?(self)
    }
}
