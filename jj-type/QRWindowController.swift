//
//  QRWindowController.swift
//  jj-type
//
//  Dedicated QR window (⌥Q, utils-6): two grouped cards — 生成 (type-to-
//  generate with a debounced preview, save PNG / copy image) and 解析
//  (clipboard image OR a picked image file → Vision decode, copy / open URL).
//  Built on the TranslationWindow skeleton (persisted frame, Esc/⌘W close
//  the WINDOW, never the app).
//

import AppKit
import UniformTypeIdentifiers

final class QRWindowController: NSWindowController, NSTextViewDelegate {
    /// Explicit frame persistence (TranslationWindow pattern): autosave alone
    /// is clobbered on the recreate path; our own key wins.
    private static let frameKey = "jjtype.qrWindowFrame"

    // 生成 card
    private let inputTextView = NSTextView()
    private let previewView = NSImageView()
    private let saveButton = NSButton(title: "保存图片…", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制图片", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    // 解析 card
    private let chooseButton = NSButton(title: "选择图片…", target: nil, action: nil)
    private let decodeButton = NSButton(title: "解析剪贴板图片", target: nil, action: nil)
    private let resultTextView = NSTextView()
    private let resultCopyButton = NSButton(title: "复制结果", target: nil, action: nil)
    private let openURLButton = NSButton(title: "打开网址", target: nil, action: nil)

    private var pendingGenerate: DispatchWorkItem?
    /// Long enough that continuous typing settles before a render; renders
    /// run OFF the main actor (see regenerateNow) so they never stall typing.
    private static let generateDelay: TimeInterval = 0.45
    /// Guards against a stale background render overwriting a newer input.
    private var generateGeneration = 0
    private var statusFadeWorkItem: DispatchWorkItem?
    /// Latest generated CGImage + its PNG bytes, kept for save / copy.
    private var currentImage: CGImage?
    private var currentPNG: Data?
    private var lastPayloadURL: URL?

    convenience init() {
        let content = QRContentView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "JJType 二维码"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 560, height: 480)
        self.init(window: window)
        window.contentViewController = NSViewController()
        window.contentViewController?.view = content
        content.controller = self
        buildLayout(in: content)

        let savedRect = UserDefaults.standard.string(forKey: Self.frameKey)
            .map(NSRectFromString) ?? .zero
        if savedRect.width > 50, savedRect.height > 50 {
            window.setFrame(savedRect, display: false)
        } else {
            window.center()
        }
        window.setFrameAutosaveName("jjtype.qrWindow")
        Self.clampFrameToVisibleScreen(window)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
    }

    // MARK: - Public API

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(inputTextView)
        regenerateNow()
    }

    // MARK: - Layout

    private func buildLayout(in view: NSView) {
        // -- 生成 card：左大输入 + 右大预览（预览是视觉中心，参考桌面
        //    QR 工具主流布局：输入即改即见、操作围绕预览）---------------
        inputTextView.font = .systemFont(ofSize: 14)
        inputTextView.isRichText = false
        inputTextView.delegate = self
        let inputScroll = NSScrollView()
        inputScroll.documentView = inputTextView
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.white.cgColor
        previewView.layer?.cornerRadius = 12
        previewView.layer?.masksToBounds = true
        previewView.layer?.borderWidth = 1
        previewView.layer?.borderColor = NSColor.separatorColor.cgColor
        previewView.translatesAutoresizingMaskIntoConstraints = false

        for button in [saveButton, copyButton] {
            button.target = self
            button.bezelStyle = .rounded
        }
        saveButton.action = #selector(saveImageClicked)
        copyButton.action = #selector(copyImageClicked)
        saveButton.isEnabled = false
        copyButton.isEnabled = false
        // Primary action gets the accent tint (standards-ish emphasis).
        saveButton.bezelColor = .controlAccentColor

        let generateRow = NSStackView(views: [saveButton, copyButton])
        generateRow.spacing = 10

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let inputCaption = captionLabel("输入内容")
        let previewCaption = captionLabel("预览")

        let inputColumn = NSStackView(views: [inputCaption, inputScroll,
                                               generateRow, statusLabel])
        inputColumn.orientation = .vertical
        inputColumn.spacing = 8
        inputColumn.alignment = .leading
        inputColumn.translatesAutoresizingMaskIntoConstraints = false

        let previewColumn = NSStackView(views: [previewCaption, previewView])
        previewColumn.orientation = .vertical
        previewColumn.spacing = 8
        previewColumn.alignment = .centerX
        previewColumn.translatesAutoresizingMaskIntoConstraints = false

        let generateContent = NSStackView(views: [inputColumn, previewColumn])
        generateContent.orientation = .horizontal
        generateContent.spacing = 16
        generateContent.alignment = .top
        generateContent.distribution = .fill
        generateContent.translatesAutoresizingMaskIntoConstraints = false

        let generateBox = titledBox("生成二维码")
        generateBox.contentView = wrapInBoxContent(generateContent)
        generateBox.translatesAutoresizingMaskIntoConstraints = false

        // -- 解析 card ------------------------------------------------------
        for button in [chooseButton, decodeButton] {
            button.target = self
            button.bezelStyle = .rounded
        }
        chooseButton.action = #selector(chooseImageClicked)
        decodeButton.action = #selector(decodeClipboardClicked)

        resultTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.isRichText = false
        resultTextView.backgroundColor = .textBackgroundColor
        let resultScroll = NSScrollView()
        resultScroll.documentView = resultTextView
        resultScroll.hasVerticalScroller = true
        resultScroll.borderType = .bezelBorder
        resultScroll.translatesAutoresizingMaskIntoConstraints = false

        resultCopyButton.target = self
        resultCopyButton.action = #selector(copyResultClicked)
        resultCopyButton.bezelStyle = .rounded
        resultCopyButton.isEnabled = false
        openURLButton.target = self
        openURLButton.action = #selector(openURLClicked)
        openURLButton.bezelStyle = .rounded
        openURLButton.isEnabled = false

        let decodeRow = NSStackView(views: [chooseButton, decodeButton])
        decodeRow.spacing = 12
        let resultRow = NSStackView(views: [resultCopyButton, openURLButton])
        resultRow.spacing = 12

        let decodeContent = NSStackView(views: [decodeRow, resultScroll, resultRow])
        decodeContent.orientation = .vertical
        decodeContent.spacing = 10
        decodeContent.alignment = .centerX
        decodeContent.translatesAutoresizingMaskIntoConstraints = false

        let decodeBox = titledBox("解析二维码")
        decodeBox.contentView = wrapInBoxContent(decodeContent)
        decodeBox.translatesAutoresizingMaskIntoConstraints = false

        // -- assembly -------------------------------------------------------
        let stack = NSStackView(views: [generateBox, decodeBox])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),

            // Input column flexes; preview stays a fixed 236 pt square and
            // the input field matches that height (equal-column look).
            inputColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            previewView.widthAnchor.constraint(equalToConstant: 236),
            previewView.heightAnchor.constraint(equalToConstant: 236),
            inputScroll.widthAnchor.constraint(equalTo: inputColumn.widthAnchor),
            inputScroll.heightAnchor.constraint(equalToConstant: 236),
            generateRow.leadingAnchor.constraint(equalTo: inputColumn.leadingAnchor),

            decodeRow.widthAnchor.constraint(equalTo: decodeContent.widthAnchor, constant: -24),
            resultScroll.widthAnchor.constraint(equalTo: decodeContent.widthAnchor, constant: -24),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            resultRow.widthAnchor.constraint(equalTo: decodeContent.widthAnchor, constant: -24),
        ])
    }

    /// Small section caption shared by the two generate columns.
    private func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Group-box card with a small bold title (system-styled, dark-mode aware).
    private func titledBox(_ title: String) -> NSBox {
        let box = NSBox()
        box.title = title
        box.boxType = .secondary
        box.titleFont = .systemFont(ofSize: 12, weight: .semibold)
        box.titlePosition = .atTop
        box.contentViewMargins = NSSize(width: 0, height: 0)
        return box
    }

    /// NSBox frame-manages its contentView directly, so a constraint-driven
    /// stack assigned AS the contentView gets no edge constraints and floats
    /// loose (the "UI 全乱" bug). Wrap it: the plain container is frame-laid-
    /// out by the box, the stack is constraint-pinned inside with padding.
    private func wrapInBoxContent(_ stack: NSStackView) -> NSView {
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    // MARK: - Generation (debounced)

    func textDidChange(_ notification: Notification) {
        pendingGenerate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.regenerateNow() }
        pendingGenerate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.generateDelay, execute: work)
    }

    private func regenerateNow() {
        pendingGenerate?.cancel()
        pendingGenerate = nil
        let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            generateGeneration += 1  // invalidate any in-flight render
            currentImage = nil
            currentPNG = nil
            previewView.image = nil
            saveButton.isEnabled = false
            copyButton.isEnabled = false
            setStatus("", color: .secondaryLabelColor, fades: false)
            return
        }
        generateGeneration += 1
        let generation = generateGeneration
        setStatus("生成中…", color: .secondaryLabelColor, fades: false)
        // Rendering (CIContext + PNG encode) goes to a background task — on
        // the main actor it made typing feel janky; a generation token keeps
        // a stale render from overwriting a newer input.
        Task { @MainActor [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { () -> (CGImage, Data)? in
                guard let image = try? QRService.generateQR(for: text) else { return nil }
                let png = NSBitmapImageRep(cgImage: image)
                    .representation(using: .png, properties: [:])
                return (image, png ?? Data())
            }.value
            guard let self, generation == self.generateGeneration else { return }
            guard let (image, png) = rendered else {
                self.currentImage = nil
                self.currentPNG = nil
                self.previewView.image = nil
                self.saveButton.isEnabled = false
                self.copyButton.isEnabled = false
                self.setStatus("生成失败", color: .systemRed, fades: true)
                return
            }
            self.currentImage = image
            self.currentPNG = png
            self.previewView.image = NSImage(cgImage: image, size: NSSize(width: 236, height: 236))
            self.saveButton.isEnabled = true
            self.copyButton.isEnabled = true
            self.setStatus("已生成 · \(text.count) 字符", color: .secondaryLabelColor, fades: true)
        }
    }

    @objc private func saveImageClicked() {
        guard let png = currentPNG else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "qrcode.png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            setStatus("已保存 · \(url.lastPathComponent)", color: .secondaryLabelColor, fades: true)
        } catch {
            setStatus("保存失败：\(error.localizedDescription)", color: .systemRed, fades: true)
        }
    }

    @objc private func copyImageClicked() {
        guard let png = currentPNG else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        CaptureToast.shared.show("已复制二维码图片", symbol: "qrcode")
    }

    // MARK: - Decode (clipboard image or picked file)

    @objc private func decodeClipboardClicked() {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else {
            setStatus("剪贴板中没有图片", color: .systemRed, fades: true)
            return
        }
        decode(data: data, sourceName: "剪贴板")
    }

    /// Image-file upload path (user follow-up 2026-11-04).
    @objc private func chooseImageClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        decode(data: data, sourceName: url.lastPathComponent)
    }

    /// Shared decode chain: image bytes → background Vision → result UI.
    private func decode(data: Data, sourceName: String) {
        guard let image = NSBitmapImageRep(data: data)?.cgImage else {
            setStatus("无法读取图片（\(sourceName)）", color: .systemRed, fades: true)
            return
        }
        setStatus("正在解析 \(sourceName)…", color: .secondaryLabelColor, fades: false)
        Task { @MainActor in
            do {
                let payloads = try await Task.detached(priority: .userInitiated) {
                    try QRService.recognizeQR(in: image)
                }.value
                guard let first = payloads.first, !first.isEmpty else {
                    throw QRError.noQRCode
                }
                let joined = payloads.joined(separator: "\n")
                resultTextView.string = joined
                resultCopyButton.isEnabled = true
                if payloads.count == 1,
                   let url = URL(string: first),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    lastPayloadURL = url
                    openURLButton.isEnabled = true
                } else {
                    lastPayloadURL = nil
                    openURLButton.isEnabled = false
                }
                setStatus("已识别 \(payloads.count) 个二维码", color: .secondaryLabelColor, fades: true)
            } catch {
                resultTextView.string = ""
                resultCopyButton.isEnabled = false
                openURLButton.isEnabled = false
                lastPayloadURL = nil
                setStatus((error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                          color: .systemRed, fades: true)
            }
        }
    }

    @objc private func copyResultClicked() {
        let text = resultTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        setStatus("已复制", color: .secondaryLabelColor, fades: true)
    }

    @objc private func openURLClicked() {
        guard let url = lastPayloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
        UserDefaults.standard.synchronize()
    }

    private static func clampFrameToVisibleScreen(_ window: NSWindow) {
        let frame = window.frame
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return }
        if !screens.contains(where: { $0.intersects(frame) }) {
            window.center()
            return
        }
        let best = screens.max {
            ($0.intersection(frame).width * $0.intersection(frame).height)
                < ($1.intersection(frame).width * $1.intersection(frame).height)
        }
        guard let visible = best, visible != frame else { return }
        var clamped = frame
        clamped.origin.x = min(max(clamped.origin.x, visible.minX), visible.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.origin.y, visible.minY), visible.maxY - clamped.height)
        window.setFrame(clamped, display: false)
    }

    /// SINGLE status-write helper (TranslationWindow pattern): cancels any
    /// pending fade, then re-schedules only for fade-eligible texts.
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
}

/// Esc / ⌘W close the WINDOW only (TranslationContentView pattern).
private final class QRContentView: NSView {
    fileprivate weak var controller: QRWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            controller?.window?.orderOut(nil)
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           event.keyCode == 13 || event.keyCode == 12 { // W or Q
            controller?.window?.orderOut(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
