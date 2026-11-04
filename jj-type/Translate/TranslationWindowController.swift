//
//  TranslationWindowController.swift
//  jj-type
//
//  Input-window mode for the translate hotkey (⌥+D, Bob/Easydict-style):
//  captured selection is pre-filled (with a visible source note) and translated
//  immediately; with no selection the window opens focused on the RETAINED
//  previous input/result for re-reading or retyping. Reused, never re-created.
//  Esc / click-outside dismiss.
//

import AppKit

/// Persists the last translation (It11 #2): survives window closes AND app
/// restarts via UserDefaults.
private enum LastTranslation {
    static let inputKey = "jjtype.lastTranslation.input"
    static let resultKey = "jjtype.lastTranslation.result"

    static func save(input: String, result: String) {
        UserDefaults.standard.set(input, forKey: inputKey)
        UserDefaults.standard.set(result, forKey: resultKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: inputKey)
        UserDefaults.standard.removeObject(forKey: resultKey)
    }

    static func load() -> (input: String, result: String)? {
        let defaults = UserDefaults.standard
        guard let input = defaults.string(forKey: inputKey),
              let result = defaults.string(forKey: resultKey),
              !input.isEmpty || !result.isEmpty else { return nil }
        return (input, result)
    }
}

final class TranslationWindowController: NSWindowController {
    var onTranslate: ((String) -> Void)?
    /// QR generation for the typed input (utils-5).
    var onGenerateQR: ((String) -> Void)?

    /// Explicit frame persistence (It13 fix-2): NSWindow autosave alone is
    /// clobbered on the recreate path (contentViewController assignment resizes
    /// the window after the restore) and may be lost on SIGTERM kills — our own
    /// key with immediate synchronize() wins on both counts.
    private static let frameKey = "jjtype.translationWindowFrame"

    private let inputTextView = TranslationInputTextView()
    private let translateButton = Theme.primaryButton("翻译", symbol: "globe")
    private let clearButton = Theme.button("清空", symbol: "trash")
    private let qrButton = Theme.button("二维码", symbol: "qrcode")
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultTextView = NSTextView()
    private var presenter: TranslationContentView?

    /// Character count of the captured selection currently pre-filled (nil when
    /// the user typed the text) — shown so the capture source stays visible.
    private var prefillCount: Int?
    private var statusFadeWorkItem: DispatchWorkItem?
    private var outsideMonitors: [Any] = []

    convenience init() {
        let content = TranslationContentView(frame: NSRect(x: 0, y: 0, width: 420, height: 380))
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "JJType 翻译"
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        self.init(window: window)
        // Assign the content view controller FIRST — it resizes the window to the
        // content fitting size, which is exactly what clobbered the restored frame
        // on the recreate path (It13 fix-2 root cause). Only afterwards do we
        // restore the persisted frame, so no later sizing can override it.
        window.contentViewController = NSViewController()
        window.contentViewController?.view = content
        content.controller = self
        presenter = content
        buildLayout(in: content)

        // Explicit restore from our own key (wins over autosave).
        let savedRect = UserDefaults.standard.string(forKey: Self.frameKey)
            .map(NSRectFromString) ?? .zero
        if savedRect.width > 50, savedRect.height > 50 {
            window.setFrame(savedRect, display: false)
        } else {
            window.center()
        }
        // Belt-and-braces native autosave stays enabled.
        window.setFrameAutosaveName("jjtype.translationWindow")
        Self.clampFrameToVisibleScreen(window)

        restoreLastTranslation()
        // Persist the frame on every move/resize (rare events; immediate flush).
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
        // Monitor pairing hardening (It11 #1 mode-ii): the titlebar close button
        // bypasses dismissWindow — observe willClose so monitors never leak.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statusFadeWorkItem?.cancel()
                self?.statusFadeWorkItem = nil
                self?.removeOutsideMonitors()
                self?.saveFrame()
            }
        }
    }

    // MARK: - Public API

    /// Shows the window WITHOUT activating — used while selection capture is
    /// still in flight so the original app keeps focus.
    func presentWithoutActivating() {
        prefillCount = nil
        setStatus("", color: .secondaryLabelColor, fades: false)
        setSpinner(false)
        window?.orderFrontRegardless()
        installOutsideMonitors()
    }

    /// No-selection path (It10 #4): bring to front and focus the input for
    /// typing while RETAINING the previous input + result for re-reading.
    /// The caret is placed at the end; typing naturally replaces.
    func activateAndFocusInput() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(inputTextView)
        let end = (inputTextView.string as NSString).length
        inputTextView.setSelectedRange(NSRange(location: end, length: 0))
        installOutsideMonitors()
    }

    /// Pre-fills the captured text and translates immediately (overwrites).
    func prefillAndTranslate(_ text: String) {
        inputTextView.string = text
        prefillCount = text.count
        window?.orderFrontRegardless()
        installOutsideMonitors()
        translateClicked()
    }

    /// Loading state: spinner on/off. Deliberately does NOT touch the status
    /// label or the fade timer — deferred "stop loading" calls after a result
    /// must not cancel a freshly scheduled hint fade (It10 #1 root cause).
    func setLoading(_ loading: Bool) {
        setSpinner(loading)
        if loading {
            if let prefillCount {
                setStatus("已获取选中文本（\(prefillCount) 字），正在翻译…",
                          color: .secondaryLabelColor, fades: false)
            } else {
                setStatus("正在翻译…", color: .secondaryLabelColor, fades: false)
            }
        }
    }

    func showResult(_ translation: String) {
        resultTextView.string = translation
        setSpinner(false)
        if let prefillCount {
            setStatus("已获取选中文本（\(prefillCount) 字）· 已自动复制",
                      color: .secondaryLabelColor, fades: true)
        } else {
            setStatus("已自动复制，可直接粘贴", color: .secondaryLabelColor, fades: true)
        }
        // Auto-copy: the translation lands on the pasteboard immediately.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translation, forType: .string)
        // Persist the last translation (It11 #2) — survives closes and restarts.
        LastTranslation.save(input: inputTextView.string, result: translation)
    }

    func showError(_ message: String) {
        setSpinner(false)
        setStatus(message, color: .systemRed, fades: true)
    }

    /// Single dismissal path (Esc / ⌘W / ⌘Q + outside-click).
    func dismissWindow() {
        statusFadeWorkItem?.cancel()
        statusFadeWorkItem = nil
        removeOutsideMonitors()
        saveFrame()
        window?.orderOut(nil)
    }

    // MARK: - Layout & actions

    private func buildLayout(in view: NSView) {
        inputTextView.font = .systemFont(ofSize: 14)
        inputTextView.isRichText = false
        inputTextView.allowsUndo = true
        inputTextView.onReturn = { [weak self] in self?.translateClicked() }
        let inputScroll = NSScrollView()
        inputScroll.documentView = inputTextView
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = false
        inputScroll.wantsLayer = true
        inputScroll.layer?.cornerRadius = 6
        inputScroll.layer?.masksToBounds = true
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        translateButton.target = self
        translateButton.action = #selector(translateClicked)

        clearButton.target = self
        clearButton.action = #selector(clearClicked)

        qrButton.target = self
        qrButton.action = #selector(qrClicked)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true

        statusLabel.font = Theme.caption()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        resultTextView.font = .systemFont(ofSize: 14)
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.isRichText = false
        resultTextView.backgroundColor = .textBackgroundColor
        let resultScroll = NSScrollView()
        resultScroll.documentView = resultTextView
        resultScroll.hasVerticalScroller = true
        resultScroll.borderType = .noBorder
        resultScroll.drawsBackground = false
        resultScroll.wantsLayer = true
        resultScroll.layer?.cornerRadius = 6
        resultScroll.layer?.masksToBounds = true
        resultScroll.translatesAutoresizingMaskIntoConstraints = false

        let buttonsRow = NSStackView(views: [translateButton, clearButton, qrButton,
                                             spinner, statusLabel])
        buttonsRow.spacing = 12
        buttonsRow.alignment = .centerY

        // Same grouped-card language as Settings / QR windows.
        let inputCard = Theme.card()
        inputCard.content.addArrangedSubview(Theme.sectionHeader("输入"))
        inputCard.content.addArrangedSubview(inputScroll)
        inputCard.content.addArrangedSubview(buttonsRow)

        let resultCard = Theme.card()
        resultCard.content.addArrangedSubview(Theme.sectionHeader("译文"))
        resultCard.content.addArrangedSubview(resultScroll)

        let stack = NSStackView(views: [inputCard, resultCard])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            inputCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputScroll.widthAnchor.constraint(
                equalTo: inputCard.widthAnchor, constant: -Theme.cardPadding * 2),
            resultScroll.widthAnchor.constraint(
                equalTo: resultCard.widthAnchor, constant: -Theme.cardPadding * 2),
            inputScroll.heightAnchor.constraint(equalToConstant: 110),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    @objc fileprivate func translateClicked() {
        let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        setLoading(true)
        resultTextView.string = ""
        onTranslate?(text)
    }

    @objc private func clearClicked() {
        inputTextView.string = ""
        resultTextView.string = ""
        prefillCount = nil
        setStatus("", color: .secondaryLabelColor, fades: false)
        LastTranslation.clear()
        window?.makeFirstResponder(inputTextView)
    }

    /// Generates a QR code for the current input (utils-5); the result is
    /// pinned as a floating image by AppDelegate.
    @objc private func qrClicked() {
        let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setStatus("请先输入要生成二维码的内容", color: .systemRed, fades: true)
            return
        }
        onGenerateQR?(text)
    }

    // MARK: - Private

    /// Persists the current frame with an immediate flush so even a SIGTERM
    /// kill right after a move cannot lose it.
    private func saveFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
        UserDefaults.standard.synchronize()
    }

    /// Keeps the (possibly restored) frame on a visible screen — monitor
    /// configurations change between sessions. Centers when fully off-screen,
    /// otherwise clamps into the screen it overlaps most.
    private static func clampFrameToVisibleScreen(_ window: NSWindow) {
        let frame = window.frame
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return }
        if !screens.contains(where: { $0.intersects(frame) }) {
            window.center()
            return
        }
        let best = screens.max { lhs, rhs in
            (lhs.intersection(frame).width * lhs.intersection(frame).height)
                < (rhs.intersection(frame).width * rhs.intersection(frame).height)
        }
        guard let visible = best, visible != frame else { return }
        var clamped = frame
        clamped.origin.x = min(max(clamped.origin.x, visible.minX), visible.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.origin.y, visible.minY), visible.maxY - clamped.height)
        window.setFrame(clamped, display: false)
    }

    /// Restores the persisted last translation into the reused window.
    private func restoreLastTranslation() {
        guard let last = LastTranslation.load() else { return }
        inputTextView.string = last.input
        resultTextView.string = last.result
    }

    /// SINGLE status-write helper (It10 #1): always cancels any pending fade,
    /// then re-schedules the 3 s fade only for fade-eligible texts.
    private func setStatus(_ text: String, color: NSColor, fades: Bool) {
        statusFadeWorkItem?.cancel()
        statusFadeWorkItem = nil
        statusLabel.textColor = color
        statusLabel.stringValue = text
        guard fades, !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.statusLabel.stringValue = ""
        }
        statusFadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func setSpinner(_ spinning: Bool) {
        if spinning {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    /// Click-outside dismissal (mouseDown outside the window frame only, so
    /// text editing inside is never fought).
    private func installOutsideMonitors() {
        guard outsideMonitors.isEmpty else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleOutsideClick(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleOutsideClick(event) }
            return event
        }
        outsideMonitors = [global, local].compactMap { $0 }
    }

    private func removeOutsideMonitors() {
        outsideMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideMonitors = []
    }

    private func handleOutsideClick(_ event: NSEvent) {
        guard let window else { return }
        if !window.frame.contains(NSEvent.mouseLocation) {
            dismissWindow()
        }
    }
}

/// Input text view owning the Return key (It10 #2): plain Return → translate,
/// Shift+Return → newline. NSTextView's default keyDown inserts a newline, and
/// plain-Return key equivalents never reach performKeyEquivalent (no ⌘), so a
/// subclassed keyDown is the reliable interception point.
private final class TranslationInputTextView: NSTextView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36,
           !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Content view handling the Esc and ⌘Q key equivalents (Return is handled by
/// the input text view subclass above). ⌘Q dismisses the WINDOW only — the app
/// stays resident in the menu bar (our invisible main menu deliberately has no
/// Quit item, so this is the only ⌘Q behavior in this window).
private final class TranslationContentView: NSView {
    fileprivate weak var controller: TranslationWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            controller?.dismissWindow()
            return true
        }
        if event.keyCode == 12, // Q
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            controller?.dismissWindow()
            return true
        }
        if event.keyCode == 13, // W — standard close-window
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            controller?.dismissWindow()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
