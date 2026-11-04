//
//  PinWindowController.swift
//  jj-type
//
//  "钉住": keeps a finished screenshot floating on top of everything, above the
//  capture overlay too, so a new capture still shows it (the frozen frame
//  re-includes these windows, otherwise the shot would lose what is on screen).
//  Pins let clicks through while a capture session runs, so they never block a
//  selection. Right-click opens a menu (复制图片 / 保存到图片目录 / 关闭); the
//  close button and Esc still dismiss it (Esc needs JJType to be the active app,
//  which a click on the pin guarantees). A double-click must NOT throw the pin
//  away — that is the most common accidental dismissal.
//

import AppKit
import CoreGraphics

final class PinWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PinWindowController {
    /// Pins outlive the capture session, so they keep themselves alive here.
    private static var pins: [PinWindowController] = []
    private static var isCaptureActive = false

    /// Save destination for the pin's context menu, injected by AppDelegate so a
    /// pinned image lands in the same folder/format as a normal screenshot.
    static var saveSettings: () -> (directory: URL, format: CaptureFormat) = {
        let store = SettingsStore()
        return (store.captureSaveDirectory, store.captureFormat)
    }

    /// One step above the capture overlay, one below the toolbar.
    static let panelLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)

    /// Window numbers of the pins currently on screen: the capture service
    /// includes exactly these windows although it excludes our own app.
    static var onScreenWindowNumbers: Set<CGWindowID> {
        var numbers: Set<CGWindowID> = []
        for pin in pins where pin.panel.isVisible {
            let number = pin.panel.windowNumber
            if number > 0 {
                numbers.insert(CGWindowID(number))
            }
        }
        return numbers
    }

    /// While capturing, pins float above the overlay and must not eat the
    /// clicks that belong to the selection.
    static func setCaptureActive(_ active: Bool) {
        isCaptureActive = active
        for pin in pins {
            pin.panel.ignoresMouseEvents = active
        }
    }

    private let panel: PinWindow
    private let content: PinContentView
    private let image: CGImage
    private let pointSize: CGSize

    private init(image: CGImage, pointSize: CGSize, origin: CGPoint) {
        let size = CGSize(width: max(1, pointSize.width), height: max(1, pointSize.height))
        let frame = CGRect(origin: origin, size: size)
        self.image = image
        self.pointSize = size
        panel = PinWindow(contentRect: frame,
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered,
                          defer: false)
        content = PinContentView(image: image, size: size)

        panel.level = PinWindowController.panelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = PinWindowController.isCaptureActive
        panel.contentView = content

        content.onClose = { [weak self] in self?.close() }
        content.onCopy = { [weak self] in self?.copyImage() }
        content.onSave = { [weak self] in self?.saveImage() }
        panel.setFrame(frame, display: false)
    }

    static func show(image: CGImage, pointSize: CGSize, at origin: CGPoint) {
        let controller = PinWindowController(image: image, pointSize: pointSize, origin: origin)
        pins.append(controller)
        controller.panel.orderFrontRegardless()
    }

    /// Right-click → 复制: same pasteboard payload as the capture toolbar.
    private func copyImage() {
        CaptureExporter.copyToPasteboard(image, pointSize: pointSize)
        CaptureToast.shared.show("已复制到剪贴板", symbol: "doc.on.doc", duration: 1.6)
    }

    /// Right-click → 保存: writes to the configured screenshot folder, off the
    /// main actor, and reports both outcomes.
    private func saveImage() {
        let settings = PinWindowController.saveSettings()
        let image = image
        Task { @MainActor in
            do {
                let url = try await Task.detached(priority: .userInitiated) { [image] in
                    try CaptureExporter.save(image, to: settings.directory, format: settings.format)
                }.value
                CaptureToast.shared.show("已保存 \(url.lastPathComponent)",
                                         symbol: "square.and.arrow.down",
                                         duration: 2.2)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "保存图片失败"
                alert.informativeText = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func close() {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        PinWindowController.pins.removeAll { $0 === self }
    }
}

final class PinContentView: NSView, NSMenuDelegate {
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?

    private let image: CGImage
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?

    init(image: CGImage, size: CGSize) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "关闭贴图")
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.alphaValue = 0.35
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let side: CGFloat = 18
        closeButton.frame = NSRect(x: bounds.maxX - side - 6,
                                   y: bounds.maxY - side - 6,
                                   width: side,
                                   height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.alphaValue = 0.35
    }

    override func mouseDown(with event: NSEvent) {
        // A non-activating panel only receives key events while JJType is the
        // active app, so clicking the pin activates it (that is what makes Esc
        // work); the click is what the user asked for anyway. The view must also
        // be first responder, otherwise Esc reaches the window and is dropped.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        // Never close on double-click: a double-click is how people grab a
        // window, and losing a pinned shot to it is unrecoverable.
        super.mouseDown(with: event)
    }

    /// Right-click opens a menu instead of dismissing the pin: losing a pinned
    /// shot to a stray right-click is unrecoverable, and copy / save are the two
    /// things people actually want from a pin.
    override func rightMouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "复制图片", action: #selector(copyClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "保存到图片目录", action: #selector(saveClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭", action: #selector(closeClicked), keyEquivalent: "").target = self

        // A pop-up menu lives at level 101, far below the pin (screenSaver + 1),
        // so the pin is dropped to a normal floating level while the menu is up.
        // `menuDidClose` raises it again — never inline, in case the menu is
        // tracked asynchronously.
        window?.level = .floating
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func menuDidClose(_ menu: NSMenu) {
        window?.level = PinWindowController.panelLevel
        window?.orderFrontRegardless()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    @objc private func copyClicked() {
        onCopy?()
    }

    @objc private func saveClicked() {
        onSave?()
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
