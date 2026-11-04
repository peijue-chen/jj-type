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
    private let saveButton = Theme.primaryButton("保存图片…", symbol: "square.and.arrow.down")
    private let copyButton = Theme.button("复制图片", symbol: "doc.on.doc")
    private let statusLabel = NSTextField(labelWithString: "")

    // 解析 card
    private let chooseButton = Theme.button("选择图片…", symbol: "photo")
    private let decodeButton = Theme.button("解析剪贴板图片", symbol: "qrcode")
    private let resultTextView = NSTextView()
    private let resultCopyButton = Theme.button("复制结果", symbol: "doc.on.doc")
    private let openURLButton = Theme.button("打开网址", symbol: "arrow.up.forward.app")
    /// Decode feedback lives IN the decode card (not the generate status line);
    /// middle-truncation keeps a long file's name start AND extension visible,
    /// with the full name on hover.
    private let decodeStatusLabel = NSTextField(labelWithString: "")

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
        window.titlebarSeparatorStyle = .none
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
        inputTextView.font = Theme.body()
        inputTextView.isRichText = false
        inputTextView.delegate = self
        let inputScroll = makeRoundedScroll(for: inputTextView)

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.white.cgColor
        previewView.layer?.cornerRadius = 10
        previewView.layer?.masksToBounds = true
        previewView.layer?.borderWidth = 1
        previewView.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        previewView.translatesAutoresizingMaskIntoConstraints = false

        saveButton.target = self
        saveButton.action = #selector(saveImageClicked)
        copyButton.target = self
        copyButton.action = #selector(copyImageClicked)
        saveButton.isEnabled = false
        copyButton.isEnabled = false

        let generateRow = NSStackView(views: [saveButton, copyButton])
        generateRow.spacing = 10

        statusLabel.font = Theme.caption()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let inputColumn = NSStackView(views: [captionLabel("输入内容"), inputScroll,
                                               generateRow, statusLabel])
        inputColumn.orientation = .vertical
        inputColumn.spacing = 8
        inputColumn.alignment = .leading
        inputColumn.translatesAutoresizingMaskIntoConstraints = false

        let previewColumn = NSStackView(views: [captionLabel("预览"), previewView])
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

        let generateCard = Theme.card()
        generateCard.content.addArrangedSubview(sectionLabel("生成二维码"))
        generateCard.content.addArrangedSubview(generateContent)

        // -- 解析 card ------------------------------------------------------
        chooseButton.target = self
        chooseButton.action = #selector(chooseImageClicked)
        decodeButton.target = self
        decodeButton.action = #selector(decodeClipboardClicked)

        resultTextView.font = Theme.mono()
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.isRichText = false
        resultTextView.backgroundColor = .textBackgroundColor
        let resultScroll = makeRoundedScroll(for: resultTextView)

        resultCopyButton.target = self
        resultCopyButton.action = #selector(copyResultClicked)
        resultCopyButton.isEnabled = false
        openURLButton.target = self
        openURLButton.action = #selector(openURLClicked)
        openURLButton.isEnabled = false

        let decodeRow = NSStackView(views: [chooseButton, decodeButton])
        decodeRow.spacing = 12
        let resultRow = NSStackView(views: [resultCopyButton, openURLButton])
        resultRow.spacing = 12

        let decodeCard = Theme.card()
        decodeCard.content.addArrangedSubview(sectionLabel("解析二维码"))
        decodeCard.content.addArrangedSubview(decodeRow)
        decodeStatusLabel.font = Theme.caption()
        decodeStatusLabel.textColor = .secondaryLabelColor
        decodeStatusLabel.lineBreakMode = .byTruncatingMiddle
        decodeStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        decodeCard.content.addArrangedSubview(decodeStatusLabel)
        decodeCard.content.addArrangedSubview(resultScroll)
        decodeCard.content.addArrangedSubview(resultRow)

        // -- assembly -------------------------------------------------------
        let stack = NSStackView(views: [generateCard, decodeCard])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),

            generateCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            decodeCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            generateContent.widthAnchor.constraint(
                equalTo: generateCard.widthAnchor, constant: -Theme.cardPadding * 2),
            decodeRow.widthAnchor.constraint(
                equalTo: decodeCard.widthAnchor, constant: -Theme.cardPadding * 2),
            decodeStatusLabel.widthAnchor.constraint(
                equalTo: decodeCard.widthAnchor, constant: -Theme.cardPadding * 2),
            resultScroll.widthAnchor.constraint(
                equalTo: decodeCard.widthAnchor, constant: -Theme.cardPadding * 2),
            resultRow.widthAnchor.constraint(
                equalTo: decodeCard.widthAnchor, constant: -Theme.cardPadding * 2),

            // Half/half split: input column and preview column each take one
            // half minus half the 16 pt stack spacing; preview stays centered
            // in its half, both areas 236 pt tall.
            inputColumn.widthAnchor.constraint(equalTo: generateContent.widthAnchor,
                                               multiplier: 0.5, constant: -8),
            previewColumn.widthAnchor.constraint(equalTo: generateContent.widthAnchor,
                                                 multiplier: 0.5, constant: -8),
            previewView.widthAnchor.constraint(equalToConstant: 236),
            previewView.heightAnchor.constraint(equalToConstant: 236),
            inputScroll.widthAnchor.constraint(equalTo: inputColumn.widthAnchor),
            inputScroll.heightAnchor.constraint(equalToConstant: 236),
            generateRow.leadingAnchor.constraint(equalTo: inputColumn.leadingAnchor),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    /// Borderless rounded text scroller shared by the input and result areas.
    private func makeRoundedScroll(for textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    /// Small section caption shared by the two generate columns.
    private func captionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Card section header (Theme language, same as settings pages).
    private func sectionLabel(_ text: String) -> NSTextField {
        Theme.sectionHeader(text)
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

    /// Decode-card status write: middle truncation + full name on hover.
    private func setDecodeStatus(_ text: String, error: Bool = false, tooltip: String? = nil) {
        decodeStatusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        decodeStatusLabel.stringValue = text
        decodeStatusLabel.toolTip = tooltip ?? text
    }

    @objc private func decodeClipboardClicked() {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else {
            setDecodeStatus("剪贴板中没有图片", error: true)
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            decode(data: data, sourceName: url.lastPathComponent)
        } catch {
            setDecodeStatus("无法读取「\(url.lastPathComponent)」：\(error.localizedDescription)",
                            error: true, tooltip: url.path)
        }
    }

    /// Shared decode chain: image bytes → background Vision → result UI.
    private func decode(data: Data, sourceName: String) {
        guard let image = NSBitmapImageRep(data: data)?.cgImage else {
            setDecodeStatus("无法读取图片（\(sourceName)）", error: true)
            return
        }
        setDecodeStatus("正在解析 \(sourceName)…", tooltip: sourceName)
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
                setDecodeStatus("来源：\(sourceName) · 已识别 \(payloads.count) 个二维码",
                                tooltip: sourceName)
            } catch {
                resultTextView.string = ""
                resultCopyButton.isEnabled = false
                openURLButton.isEnabled = false
                lastPayloadURL = nil
                setDecodeStatus((error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription, error: true)
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
