//
//  ResultPanelController.swift
//  jj-type
//
//  Non-activating floating result panel near the mouse: loading / error /
//  result states, corrected text on top + translation below, replace-via-⌘V,
//  copy, Esc & click-outside dismissal. The panel is created once and reused.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

final class ResultPanelController: NSObject {
    private let panel: NSPanel
    private var onDismiss: (() -> Void)?

    private let stack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let correctedCaption = NSTextField(labelWithString: "纠正后")
    private let correctedLabel = NSTextField(wrappingLabelWithString: "")
    private let translationCaption = NSTextField(labelWithString: "翻译")
    private let translationLabel = NSTextField(wrappingLabelWithString: "")
    private let replaceButton = NSButton(title: "替换原文", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    private var replaceText: String?
    private var globalMonitors: [Any] = []
    private var autoDismissWorkItem: DispatchWorkItem?

    private let panelWidth: CGFloat = 380

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 120))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12

        buildLayout(in: background)
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Public states

    func showLoading(near point: NSPoint, mode: TranslateMode, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        cancelAutoDismiss()
        statusLabel.stringValue = mode == .translate ? "正在翻译…" : "正在纠正并翻译…"
        setState(.loading)
        present(near: point)
    }

    func showResult(_ result: GrammarResult, replaceEnabled: Bool) {
        let hasCorrected = !result.corrected.isEmpty
        correctedLabel.stringValue = result.corrected
        translationLabel.stringValue = result.translation
        replaceText = hasCorrected ? result.corrected : result.translation
        replaceButton.isEnabled = replaceEnabled && !(replaceText ?? "").isEmpty
        replaceButton.toolTip = replaceEnabled ? nil : "需要辅助功能权限才能替换原文"
        correctedCaption.isHidden = !hasCorrected
        correctedLabel.isHidden = !hasCorrected
        // Auto-copy (B3): the corrected text (or translation when no correction)
        // lands on the pasteboard immediately so the user can paste right away.
        if let text = replaceText, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copyButton.title = "已复制"
        } else {
            copyButton.title = "复制"
        }
        setState(.result)
        refit()
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        replaceText = nil
        setState(.error)
        // The panel must become visible when the error is the first thing to show
        // (e.g. the no-active-provider path runs before any showLoading).
        if panel.isVisible {
            refit()
        } else {
            present(near: NSEvent.mouseLocation)
        }
    }

    func dismiss() {
        cancelAutoDismiss()
        removeDismissMonitors()
        panel.orderOut(nil)
        onDismiss?()
        onDismiss = nil
    }

    // MARK: - Layout & states

    private enum PanelState { case loading, error, result }

    private func buildLayout(in view: NSView) {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.preferredMaxLayoutWidth = panelWidth - 48

        for caption in [correctedCaption, translationCaption] {
            caption.font = .systemFont(ofSize: 11, weight: .semibold)
            caption.textColor = .secondaryLabelColor
        }
        for label in [correctedLabel, translationLabel] {
            label.font = .systemFont(ofSize: 13)
            label.isSelectable = true
            label.lineBreakMode = .byWordWrapping
            label.preferredMaxLayoutWidth = panelWidth - 48
            label.maximumNumberOfLines = 8
        }

        configureActionButton(replaceButton, action: #selector(replaceClicked))
        configureActionButton(copyButton, action: #selector(copyClicked))
        configureActionButton(closeButton, action: #selector(closeClicked))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let loadingRow = NSStackView(views: [spinner, statusLabel])
        loadingRow.spacing = 8
        let buttonsRow = NSStackView(views: [replaceButton, copyButton, closeButton])
        buttonsRow.spacing = 12

        stack.addArrangedSubview(loadingRow)
        stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(correctedCaption)
        stack.addArrangedSubview(correctedLabel)
        stack.addArrangedSubview(translationCaption)
        stack.addArrangedSubview(translationLabel)
        stack.addArrangedSubview(buttonsRow)
    }

    private func configureActionButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
    }

    private func setState(_ state: PanelState) {
        let loading = stack.arrangedSubviews.count > 0 ? stack.arrangedSubviews[0] : nil
        let buttons = stack.arrangedSubviews.last
        loading?.isHidden = state != .loading
        errorLabel.isHidden = state != .error
        correctedCaption.isHidden = state != .result || correctedLabel.stringValue.isEmpty
        correctedLabel.isHidden = state != .result || correctedLabel.stringValue.isEmpty
        translationCaption.isHidden = state != .result
        translationLabel.isHidden = state != .result
        buttons?.isHidden = state == .loading
    }

    private func refit() {
        panel.setContentSize(NSSize(width: panelWidth, height: stack.fittingSize.height))
        panel.contentView?.needsLayout = true
    }

    private func present(near point: NSPoint) {
        refit()
        positionPanel(near: point)
        removeDismissMonitors()
        installDismissMonitors()
        panel.orderFrontRegardless()
    }

    private func positionPanel(near point: NSPoint) {
        let size = panel.frame.size
        var origin = NSPoint(x: point.x + 16, y: point.y - 16 - size.height)
        // Flip below the cursor when the panel would cross the top edge.
        if let screen = screenContaining(point) {
            let visible = screen.visibleFrame
            if origin.y + size.height > visible.maxY {
                origin.y = point.y - 24 - size.height
            }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }

    private func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    // MARK: - Dismiss monitors (Esc anywhere + click outside)

    private func installDismissMonitors() {
        let globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleOutsideClick(event) }
        }
        let globalKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKeyEvent(event) }
        }
        let localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKeyEvent(event)
            }
            return event
        }
        // Local mouse monitor: clicks on our own windows (settings/guide/status menu)
        // are outside the panel and must dismiss it too — global monitors do not see them.
        let localMouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleOutsideClick(event)
            }
            return event
        }
        globalMonitors = [globalMouse, globalKey, localKey, localMouse].compactMap { $0 }
    }

    private func removeDismissMonitors() {
        globalMonitors.forEach { NSEvent.removeMonitor($0) }
        globalMonitors = []
    }

    private func handleOutsideClick(_ event: NSEvent) {
        let screenLocation = NSEvent.mouseLocation
        if !panel.frame.contains(screenLocation) { dismiss() }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { dismiss() }
    }

    // MARK: - Actions

    @objc private func replaceClicked() {
        guard let text = replaceText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Small delay so the target app regains paste readiness after panel interaction.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.postCommandV()
            self?.dismiss()
        }
    }

    @objc private func copyClicked() {
        if let text = replaceText, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        copyButton.title = "已复制"
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        autoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    @objc private func closeClicked() {
        dismiss()
    }

    private func cancelAutoDismiss() {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        copyButton.title = "复制"
    }

    /// Synthesizes ⌘V to the session event tap (needs Accessibility).
    private func postCommandV() {
        let keyCodeV: CGKeyCode = 9
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        keyDown?.flags = CGEventFlags.maskCommand
        keyUp?.flags = CGEventFlags.maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
