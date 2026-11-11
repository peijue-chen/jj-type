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
    /// AI quick-action chips (built-ins + custom), shown in the result state.
    private let actionsRow = NSStackView()

    /// Source text of the last capture: the speaker reads it, and its IPA is
    /// shown when it is a single English word. Set by AppDelegate before each
    /// show (the panel never displays the source itself).
    var sourceText: String = ""
    private let sourceSpeakButton = Theme.iconButton(symbol: "speaker.wave.2", toolTip: "朗读原文")
    private let sourceCaption = NSTextField(labelWithString: "原文")
    private let sourcePhoneticLabel = NSTextField(labelWithString: "")
    private let sourceRow = NSStackView()
    private var speechObserver: NSObjectProtocol?
    /// Text the current IPA label belongs to — speech-state notifications call
    /// `refreshSourceRow()` repeatedly and must not re-run the lookup.
    private var phoneticSourceText = ""

    /// Set by AppDelegate before each flow; clicking a chip fires this.
    var quickActions: [QuickAction] = []
    var onQuickAction: ((QuickAction) -> Void)?
    /// QR chip: generates a code for the captured source text (utils-5).
    var onGenerateQR: (() -> Void)?

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
        // Speaker glyph follows the shared speech state (a stop from another
        // surface must reset this panel too).
        speechObserver = NotificationCenter.default.addObserver(
            forName: .jjTypeSpeechStateChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSourceRow() }
            }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Public states

    func showLoading(near point: NSPoint, mode: TranslateMode, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        cancelAutoDismiss()
        statusLabel.stringValue = mode == .translate ? "正在翻译…" : "正在纠正并翻译…"
        // Chips show DURING loading too (utils-3 follow-up): the actions are
        // visible the moment the panel appears, and clicking one cancels the
        // in-flight request and switches action (latest-wins in AppDelegate).
        rebuildQuickActionButtons()
        setState(.loading)
        present(near: point)
    }

    func showResult(_ result: GrammarResult, replaceEnabled: Bool) {
        let hasCorrected = !result.corrected.isEmpty
        // A quick action may have re-titled the caption; restore the default.
        translationCaption.stringValue = "翻译"
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
        rebuildQuickActionButtons()
        refreshSourceRow()
        refit()
    }

    /// Quick action in flight: same loading state, action-specific label.
    /// When triggered from the selection bar the panel is NOT on screen yet —
    /// it must present itself near the cursor or the action looks dead.
    func showQuickLoading(actionName: String) {
        cancelAutoDismiss()
        statusLabel.stringValue = "正在\(actionName)…"
        rebuildQuickActionButtons()
        setState(.loading)
        if panel.isVisible {
            refit()
        } else {
            present(near: NSEvent.mouseLocation)
        }
    }

    /// Quick action result: single text block titled with the action name,
    /// same replace / copy affordances as the grammar result.
    func showQuickResult(title: String, text: String, replaceEnabled: Bool) {
        cancelAutoDismiss()
        correctedLabel.stringValue = ""
        translationCaption.stringValue = title
        translationLabel.stringValue = text
        replaceText = text
        replaceButton.isEnabled = replaceEnabled && !text.isEmpty
        replaceButton.toolTip = replaceEnabled ? nil : "需要辅助功能权限才能替换原文"
        if !text.isEmpty {
            // Auto-copy parity with showResult (B3): result ready to paste.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copyButton.title = "已复制"
        } else {
            copyButton.title = "复制"
        }
        setState(.result)
        rebuildQuickActionButtons()
        refreshSourceRow()
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
        // The panel is the only stop control — never leave a voice talking to
        // a dismissed panel.
        SpeechService.shared.stop()
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
            caption.textColor = Theme.accent
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
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8
        let buttonsRow = NSStackView(views: [replaceButton, copyButton, closeButton])
        buttonsRow.spacing = 12

        // Source row: 原文 + speaker + IPA of the captured text (result only).
        sourceSpeakButton.target = self
        sourceSpeakButton.action = #selector(speakSourceClicked)
        sourceCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        sourceCaption.textColor = Theme.accent
        sourcePhoneticLabel.font = .systemFont(ofSize: 11)
        sourcePhoneticLabel.textColor = .secondaryLabelColor
        sourcePhoneticLabel.lineBreakMode = .byTruncatingTail
        sourcePhoneticLabel.isHidden = true
        sourceRow.orientation = .horizontal
        sourceRow.alignment = .centerY
        sourceRow.spacing = 6
        sourceRow.addArrangedSubview(sourceCaption)
        sourceRow.addArrangedSubview(sourceSpeakButton)
        sourceRow.addArrangedSubview(sourcePhoneticLabel)
        sourceRow.isHidden = true
        // The panel width is fixed: a long IPA (a long word) must truncate,
        // never overflow the rounded edge.
        sourcePhoneticLabel.setContentCompressionResistancePriority(.defaultLow,
                                                                    for: .horizontal)
        sourceRow.widthAnchor.constraint(lessThanOrEqualToConstant: panelWidth - 32)
            .isActive = true

        stack.addArrangedSubview(loadingRow)
        stack.addArrangedSubview(sourceRow)
        stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(correctedCaption)
        stack.addArrangedSubview(correctedLabel)
        stack.addArrangedSubview(translationCaption)
        stack.addArrangedSubview(translationLabel)
        stack.addArrangedSubview(actionsRow)
        stack.addArrangedSubview(buttonsRow)
    }

    /// Rebuilds the quick-action chips from `quickActions` plus the trailing
    /// QR chip (always present — generation needs no AI provider). Called on
    /// every result state so edits in Settings apply to the next show.
    private func rebuildQuickActionButtons() {
        actionsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, action) in quickActions.enumerated() {
            let button = NSButton(title: action.name, target: self,
                                  action: #selector(quickActionClicked(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            actionsRow.addArrangedSubview(button)
        }
        let qrButton = NSButton(title: "二维码", target: self,
                                action: #selector(qrChipClicked))
        qrButton.bezelStyle = .rounded
        qrButton.controlSize = .small
        actionsRow.addArrangedSubview(qrButton)
    }

    @objc private func quickActionClicked(_ sender: NSButton) {
        guard quickActions.indices.contains(sender.tag) else { return }
        onQuickAction?(quickActions[sender.tag])
    }

    @objc private func qrChipClicked() {
        onGenerateQR?()
    }

    private func configureActionButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
        // The replace action is the emphasis of the result state — accent fill.
        if button === replaceButton {
            button.bezelColor = Theme.accent
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ])
        }
    }

    private func setState(_ state: PanelState) {
        let loading = stack.arrangedSubviews.count > 0 ? stack.arrangedSubviews[0] : nil
        let buttons = stack.arrangedSubviews.last
        loading?.isHidden = state != .loading
        sourceRow.isHidden = state != .result || sourceText.isEmpty
        errorLabel.isHidden = state != .error
        correctedCaption.isHidden = state != .result || correctedLabel.stringValue.isEmpty
        correctedLabel.isHidden = state != .result || correctedLabel.stringValue.isEmpty
        translationCaption.isHidden = state != .result
        translationLabel.isHidden = state != .result
        // Chips stay visible in loading AND result states (only errors hide
        // them) — the panel must show its action options immediately.
        actionsRow.isHidden = state == .error
        buttons?.isHidden = state == .loading
    }

    private func refit() {
        panel.setContentSize(NSSize(width: panelWidth, height: stack.fittingSize.height))
        panel.contentView?.needsLayout = true
        // The origin stays fixed while the height grows: re-clamp vertically
        // so a tall result (arriving after the panel was positioned) never
        // crosses the top of the screen.
        if panel.isVisible,
           let visible = screenContaining(panel.frame.origin)?.visibleFrame {
            let ceiling = max(visible.minY + 12, visible.maxY - panel.frame.height - 8)
            var origin = panel.frame.origin
            origin.y = min(max(origin.y, visible.minY + 12), ceiling)
            if origin.y != panel.frame.origin.y {
                panel.setFrameOrigin(origin)
            }
        }
    }

    private func present(near point: NSPoint) {
        refit()
        positionPanel(near: point)
        removeDismissMonitors()
        installDismissMonitors()
        panel.orderFrontRegardless()
    }

    /// Right-and-below the selection by default; when there is not enough
    /// room below (text at the bottom of the screen) the panel flips ABOVE
    /// the selection — clamping to the screen bottom instead would cover the
    /// text and park the panel in the Dock's slide-in strip.
    private func positionPanel(near point: NSPoint) {
        let size = panel.frame.size
        var origin = NSPoint(x: point.x + 16, y: point.y - 16 - size.height)
        if let screen = screenContaining(point) {
            let visible = screen.visibleFrame
            // Bottom flip: the natural spot would fall off the screen → put
            // the panel above the selection instead.
            if origin.y < visible.minY + 12 {
                origin.y = point.y + 24
            }
            // Top guard: a tall panel flipped up must still fit; overlapping
            // the cursor is the acceptable fallback, off-screen is not.
            origin.y = min(max(origin.y, visible.minY + 12),
                           max(visible.minY + 12, visible.maxY - size.height - 8))
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
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

    // MARK: - Source speaker & phonetics

    @objc private func speakSourceClicked() {
        SpeechService.shared.toggle(sourceText)
    }

    /// Speaker glyph + IPA label for the captured source text. The row keeps a
    /// constant height (the button is always there), so a late phonetic result
    /// never resizes the panel.
    private func refreshSourceRow() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let speech = SpeechService.shared
        sourceSpeakButton.isEnabled = !text.isEmpty
        Theme.setSymbol(speech.isSpeaking(text) ? "stop.fill" : "speaker.wave.2",
                        on: sourceSpeakButton)
        sourceSpeakButton.toolTip = speech.isSpeaking(text) ? "停止朗读" : "朗读原文"
        guard text != phoneticSourceText else { return }
        phoneticSourceText = text
        sourcePhoneticLabel.stringValue = ""
        sourcePhoneticLabel.isHidden = true
        guard PhoneticService.isSingleEnglishWord(text) else { return }
        PhoneticService.lookup(text) { [weak self] phonetic in
            guard let self, self.phoneticSourceText == text else { return }
            self.sourcePhoneticLabel.stringValue = phonetic ?? ""
            self.sourcePhoneticLabel.isHidden = (phonetic ?? "").isEmpty
        }
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
