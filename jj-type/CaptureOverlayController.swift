//
//  CaptureOverlayController.swift
//  jj-type
//
//  Orchestrates one screenshot session: permission → freeze all displays →
//  snapshot windows → build one overlay per display → own the authoritative
//  selection (global coordinates) → toolbar → crop → restore focus.
//
//  Only one session can be active at a time.
//

import AppKit
import CoreGraphics

final class CaptureOverlayController {
    private(set) var isActive = false
    /// Selection in AppKit global coordinates (bottom-left origin).
    private(set) var selection: CGRect?
    private(set) var isToolbarVisible = false

    /// Called with the flattened image for the "save" actions (after teardown).
    /// `copied` is true when the image also went to the pasteboard, so the
    /// handler can report copy + save with a single message.
    var onFinish: ((CGImage, Bool) -> Void)?
    var onCancel: (() -> Void)?

    private var displays: [CapturedDisplay] = []
    private var windows: [WindowSnapshot] = []
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var toolbar: CaptureToolbarController?
    private var previousApp: NSRunningApplication?

    // MARK: - Annotation state (authoritative, shared by every overlay)

    private(set) var annotations: [AnnotationItem] = []
    private(set) var activeTool: AnnotationTool?
    private(set) var style = AnnotationStyle()
    var hasAnnotations: Bool { !annotations.isEmpty }

    /// Snapshots of `annotations`; erase / add both go through it so undo is
    /// uniform. Bounded so a long session cannot grow without limit.
    private var history: [[AnnotationItem]] = [[]]
    private var historyIndex = 0
    private var nextAnnotationID = 1

    // MARK: - Session lifecycle

    func begin() async {
        guard !isActive else { return }
        isActive = true
        previousApp = NSWorkspace.shared.frontmostApplication

        let targets = NSScreen.screens.compactMap(Self.target(for:))
        guard !targets.isEmpty else {
            finishWithError(ScreenCaptureError.noDisplays.errorDescription ?? "未检测到显示器")
            return
        }

        // Pins float above the overlay during the session, so they must not eat
        // the clicks that belong to the selection — but they must still be
        // photographed, otherwise the shot would lose what the user sees.
        PinWindowController.setCaptureActive(true)
        let pinnedWindowIDs = PinWindowController.onScreenWindowNumbers

        let captured: [CapturedDisplay]
        do {
            captured = try await ScreenCaptureService.captureAllDisplays(targets,
                                                                        includingOwnWindowIDs: pinnedWindowIDs)
        } catch {
            finishWithError(Self.message(for: error))
            // "Granted but not relaunched yet" lands here: point at the guide.
            if let captureError = error as? ScreenCaptureError,
               case .permissionDenied = captureError {
                ScreenCaptureGuideWindowController.shared.showIfNeeded(force: true)
            }
            return
        }
        // The session may have been cancelled while the capture was in flight.
        guard isActive else { return }

        displays = captured
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        windows = WindowHitTester.snapshot(primaryMaxY: primaryMaxY)
        presentOverlays()
    }

    func cancel() {
        guard isActive else { return }
        teardown()
        onCancel?()
    }

    // MARK: - Selection

    func setSelection(_ rect: CGRect?) {
        let previous = selection
        if let rect {
            selection = SelectionGeometry.clamped(rect, to: desktopBounds)
        } else {
            selection = nil
        }
        // The toolbar belongs to a selection: it only goes away when the frame
        // does. Moving / resizing keeps it up (it is repositioned on mouse-up).
        if selection == nil, isToolbarVisible {
            hideToolbar()
        }
        // Drag events arrive at mouse-move rate: repaint only the rectangles that
        // actually changed instead of every display's full 5K frame.
        invalidate(from: previous, to: selection)
    }

    private func invalidate(from previous: CGRect?, to current: CGRect?) {
        guard previous != nil || current != nil else { return }
        for window in overlayWindows {
            guard let view = window.contentView as? CaptureOverlayView else { continue }
            var dirty: CGRect?
            for candidate in [previous, current].compactMap({ $0 }) {
                let overlap = candidate.intersection(view.screenFrame)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
                let local = overlap.offsetBy(dx: -view.screenFrame.minX, dy: -view.screenFrame.minY)
                // Handles stick out by 3.5pt and the size badge sits above.
                let padded = local.insetBy(dx: -32, dy: -32)
                dirty = dirty.map { $0.union(padded) } ?? padded
            }
            if let dirty {
                view.setNeedsDisplay(dirty)
            }
        }
    }

    /// A drag finished: float the toolbar next to the selection.
    func selectionCommitted() {
        guard let selection, selection.width >= 3, selection.height >= 3 else { return }
        showToolbar(anchor: selection)
    }

    func confirm(_ action: CaptureToolbarController.Action) {
        guard let currentSelection = selection else { return }
        if action == .close {
            cancel()
            return
        }

        let base: CGImage
        do {
            base = try ScreenCaptureService.crop(selection: currentSelection, from: displays)
        } catch {
            finishWithError(Self.message(for: error))
            return
        }

        let items = annotations
        let pointSize = currentSelection.size
        let origin = currentSelection.origin

        switch action {
        case .qr:
            // QR reads the COMPOSITED pixels — what the user sees (annotations
            // may complete a partially drawn code; Vision tolerates the noise).
            teardown()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let image = await Self.composite(base: base, selection: currentSelection,
                                                 items: items)
                self.recognizeQR(from: image)
            }
        case .recognize:
            // OCR reads the untouched pixels: annotations would only add noise.
            teardown()
            recognize(from: base)
        case .copy, .copyAndSave, .save, .pin:
            // Close first so the alert (on failure) and the user's next click
            // land on the original app, not on the overlay.
            teardown()
            Task { @MainActor [weak self] in
                let image = await Self.composite(base: base, selection: currentSelection, items: items)
                switch action {
                case .copy:
                    CaptureExporter.copyToPasteboard(image, pointSize: pointSize)
                    CaptureToast.shared.show("已复制到剪贴板", symbol: "doc.on.doc")
                case .copyAndSave:
                    // Double-click keeps the shot: copy for pasting right away and
                    // write the file as well. One toast (from the save handler)
                    // reports both, so the copy does not flash a second message.
                    CaptureExporter.copyToPasteboard(image, pointSize: pointSize)
                    self?.onFinish?(image, true)
                case .pin:
                    PinWindowController.show(image: image, pointSize: pointSize, at: origin)
                    CaptureToast.shared.show("已钉住 — 右键可复制 / 保存，Esc 关闭", symbol: "pin")
                case .save:
                    self?.onFinish?(image, false)
                default:
                    break
                }
            }
        case .close:
            break
        }
    }

    // MARK: - Annotations

    func setTool(_ tool: AnnotationTool?) {
        guard activeTool != tool else { return }
        activeTool = tool
        refreshToolbarState()
        for window in overlayWindows {
            guard let view = window.contentView as? CaptureOverlayView else { continue }
            view.toolDidChange()
            if tool == .mosaic {
                // Build the blocky source now, not on the first stroke.
                view.prepareMosaic()
            }
        }
        // A toolbar click must not take keyboard focus away from the overlay.
        if let keyWindow = overlayWindows.first(where: { $0.isKeyWindow }),
           let view = keyWindow.contentView {
            keyWindow.makeFirstResponder(view)
        }
    }

    func setStyle(_ style: AnnotationStyle) {
        guard self.style != style else { return }
        self.style = style
        refreshToolbarState()
        // A text editor that is already open must follow the new colour / font /
        // size immediately, not on the next click.
        for window in overlayWindows {
            (window.contentView as? CaptureOverlayView)?.applyStyleToTextEditor(style)
        }
    }

    func commitAnnotation(_ item: AnnotationItem) {
        var committed = item
        committed.id = nextAnnotationID
        nextAnnotationID += 1
        if committed.tool == .number {
            // Derived from what is on screen, so undo + re-place reuses "1".
            let highest = annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0
            committed.number = highest + 1
        }
        annotations.append(committed)
        pushHistory()
        refreshToolbarState()
        invalidateAnnotations([committed])
    }

    func commitTextAnnotation(_ text: String, at point: CGPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commitAnnotation(AnnotationItem(tool: .text,
                                        start: point,
                                        color: style.color,
                                        lineWidth: style.lineWidth,
                                        text: trimmed,
                                        fontName: style.font.name,
                                        fontSize: style.fontSize))
    }

    func commitNumberAnnotation(at point: CGPoint) {
        commitAnnotation(AnnotationItem(tool: .number,
                                        start: point,
                                        color: style.color,
                                        lineWidth: style.lineWidth))
    }

    func eraseAnnotation(at point: CGPoint) {
        guard let index = annotations.lastIndex(where: { $0.hitTest(point) }) else { return }
        let removed = annotations.remove(at: index)
        pushHistory()
        refreshToolbarState()
        invalidateAnnotations([removed])
    }

    func undoAnnotation() {
        guard canUndo else { return }
        let previous = annotations
        historyIndex -= 1
        annotations = history[historyIndex]
        refreshToolbarState()
        invalidateAnnotations(previous + annotations)
    }

    func redoAnnotation() {
        guard canRedo else { return }
        let previous = annotations
        historyIndex += 1
        annotations = history[historyIndex]
        refreshToolbarState()
        invalidateAnnotations(previous + annotations)
    }

    private var canUndo: Bool { historyIndex > 0 }
    private var canRedo: Bool { historyIndex < history.count - 1 }

    private func pushHistory() {
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(annotations)
        if history.count > 64 {
            history.removeFirst(history.count - 64)
            // Undo-all must still be able to reach "nothing drawn".
            history[0] = []
        }
        historyIndex = history.count - 1
    }

    private func refreshToolbarState() {
        toolbar?.apply(tool: activeTool, style: style, canUndo: canUndo, canRedo: canRedo)
    }

    /// Repaints only the displays that intersect the given annotations.
    private func invalidateAnnotations(_ items: [AnnotationItem]) {
        guard let first = items.first else { return }
        var rect = first.bounds
        for item in items.dropFirst() {
            rect = rect.union(item.bounds)
        }
        invalidateGlobal(rect)
    }

    private func invalidateGlobal(_ rect: CGRect) {
        for window in overlayWindows {
            guard let view = window.contentView as? CaptureOverlayView else { continue }
            let overlap = rect.intersection(view.screenFrame)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let local = overlap.offsetBy(dx: -view.screenFrame.minX, dy: -view.screenFrame.minY)
            view.setNeedsDisplay(local.insetBy(dx: -4, dy: -4))
        }
    }

    private func resetAnnotations() {
        annotations.removeAll()
        history = [[]]
        historyIndex = 0
        activeTool = nil
        nextAnnotationID = 1
    }

    // MARK: - Overlay construction

    private static func target(for screen: NSScreen) -> DisplayTarget? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return DisplayTarget(displayID: number.uint32Value,
                             frame: screen.frame,
                             scale: screen.backingScaleFactor)
    }

    private func presentOverlays() {
        for display in displays {
            let window = CaptureOverlayWindow(screenFrame: display.screenFrame)
            let view = CaptureOverlayView(display: display, windows: windows, session: self)
            window.contentView = view
            overlayWindows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let keyWindow = overlayWindows.first { $0.frame.contains(mouse) } ?? overlayWindows.first
        for window in overlayWindows {
            window.orderFrontRegardless()
        }
        keyWindow?.makeKeyAndOrderFront(nil)
        if let view = keyWindow?.contentView {
            keyWindow?.makeFirstResponder(view)
        }
    }

    private func showToolbar(anchor: CGRect) {
        let controller: CaptureToolbarController
        if let existing = toolbar {
            controller = existing
        } else {
            let created = CaptureToolbarController()
            created.onAction = { [weak self] action in
                self?.confirm(action)
            }
            created.onToolChanged = { [weak self] tool in
                self?.setTool(tool)
            }
            created.onStyleChanged = { [weak self] style in
                self?.setStyle(style)
            }
            created.onUndo = { [weak self] in
                self?.undoAnnotation()
            }
            created.onRedo = { [weak self] in
                self?.redoAnnotation()
            }
            toolbar = created
            controller = created
        }
        isToolbarVisible = true
        controller.apply(tool: activeTool, style: style, canUndo: canUndo, canRedo: canRedo)
        controller.show(anchor: anchor)
        for window in overlayWindows {
            (window.contentView as? CaptureOverlayView)?.toolDidChange()
        }
    }

    private func hideToolbar() {
        guard isToolbarVisible else { return }
        isToolbarVisible = false
        toolbar?.hide()
        // Tools only exist while their toolbar is up.
        activeTool = nil
        for window in overlayWindows {
            (window.contentView as? CaptureOverlayView)?.toolDidChange()
        }
    }

    private var desktopBounds: CGRect {
        displays.reduce(CGRect.null) { $0.union($1.screenFrame) }
    }

    // MARK: - Teardown

    private func teardown() {
        toolbar?.hide()
        isToolbarVisible = false
        // Pins become draggable / closable again.
        PinWindowController.setCaptureActive(false)

        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
        displays.removeAll()
        windows.removeAll()
        selection = nil
        isActive = false
        resetAnnotations()

        // Hand focus back so the user keeps typing where they were.
        if let app = previousApp, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate()
        }
        previousApp = nil
    }

    private func finishWithError(_ message: String) {
        teardown()
        presentAlert(title: "截图失败", message: message)
        onCancel?()
    }

    // MARK: - Output

    /// Flattens annotations into the crop off the main actor; returns the base
    /// image untouched when nothing was drawn.
    private static func composite(base: CGImage,
                                  selection: CGRect,
                                  items: [AnnotationItem]) async -> CGImage {
        guard !items.isEmpty else { return base }
        return await Task.detached(priority: .userInitiated) {
            AnnotationRenderer.compose(base, selection: selection, items: items)
        }.value
    }

    /// QR decode (utils-5): payloads go straight to the pasteboard; a single
    /// http(s) payload additionally offers the open action. Never silent.
    private func recognizeQR(from image: CGImage) {
        CaptureToast.shared.show("正在识别二维码…", symbol: "qrcode", duration: 20)
        Task { @MainActor in
            do {
                let payloads = try await Task.detached(priority: .userInitiated) {
                    try QRService.recognizeQR(in: image)
                }.value
                guard let first = payloads.first, !first.isEmpty else {
                    throw QRError.noQRCode
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(payloads.joined(separator: "\n"), forType: .string)

                if payloads.count == 1,
                   let url = URL(string: first),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    CaptureToast.shared.show("已识别二维码，已复制到剪贴板",
                                             symbol: "qrcode", duration: 1.4)
                    // A modal under the user's frontmost window is unreachable —
                    // activate first (same reason as the system-command alerts).
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "识别到网址"
                    alert.informativeText = first
                    alert.addButton(withTitle: "打开网址")
                    alert.addButton(withTitle: "关闭")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    CaptureToast.shared.show("已识别 \(payloads.count) 个二维码，已复制到剪贴板",
                                             symbol: "qrcode", duration: 2.2)
                }
            } catch let error as QRError {
                CaptureToast.shared.show(error.localizedDescription, symbol: "qrcode", duration: 2.2)
            } catch {
                CaptureToast.shared.show(Self.message(for: error), symbol: "qrcode", duration: 2.2)
            }
        }
    }

    /// Decision #7: the recognised text goes straight to the pasteboard — and
    /// the result is never silent, success or failure.
    private func recognize(from image: CGImage) {
        // The overlay is already gone and OCR takes a moment: never leave the
        // user staring at a frozen-then-empty screen.
        CaptureToast.shared.show("正在识别文字…", symbol: "text.viewfinder", duration: 20)
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try TextRecognizer.recognize(image)
                }.value
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(result.text, forType: .string)
                CaptureToast.shared.show("已识别 \(result.lineCount) 行文字，已复制到剪贴板",
                                         symbol: "text.viewfinder",
                                         duration: 2.2)
            } catch let error as TextRecognitionError {
                switch error {
                case .noText:
                    CaptureToast.shared.show("未识别到文字 — 可框选更清晰的文字区域后重试",
                                             symbol: "exclamationmark.triangle.fill",
                                             duration: 2.8)
                case .failed(let message):
                    CaptureToast.shared.hide()
                    presentAlert(title: "识别文字失败", message: message)
                }
            } catch {
                CaptureToast.shared.hide()
                presentAlert(title: "识别文字失败", message: Self.message(for: error))
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
