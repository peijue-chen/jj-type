//
//  CaptureOverlayView.swift
//  jj-type
//
//  One display's frozen frame + dark mask + selection (8 handles, size badge) +
//  hovered-window highlight. Owns the mouse/keyboard interaction of the capture
//  session; the authoritative selection lives in CaptureOverlayController
//  (global coordinates) so a drag can span displays.
//
//  Deliberately no magnifier: a 6x loupe parked next to the cursor reads as a
//  dark blob following the pointer, and the requirement is "only the selection
//  is bright". The dim mask alone carries the focus.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

final class CaptureOverlayView: NSView {
    private enum DragMode {
        case idle
        case dragging
        case moving
        case resizing(SelectionHandle)
    }

    private let display: CapturedDisplay
    private let windows: [WindowSnapshot]
    private weak var session: CaptureOverlayController?

    private var dragMode: DragMode = .idle
    /// Global point where the mouse went down.
    private var dragAnchor: CGPoint = .zero
    /// Global selection captured at mouse-down (moving / resizing).
    private var dragStartSelection: CGRect = .zero
    private var hoverWindowRect: CGRect?
    private var trackingArea: NSTrackingArea?
    /// Stroke being dragged right now (kept out of the session until mouse-up).
    private var inProgressItem: AnnotationItem?
    private var isErasing = false
    /// Time of the last freehand dot committed by a plain click. A double-click
    /// starts with such a click, so its dot is undone before the shot is kept.
    private var lastClickDotTime: TimeInterval?
    private var textEditor: NSTextField?
    private var textOrigin: CGPoint = .zero
    /// Pixelated frozen frame, built on the first mosaic stroke only.
    private var mosaicCache: CGImage?
    private var isPreparingMosaic = false

    private let handleSize: CGFloat = 7

    init(display: CapturedDisplay,
         windows: [WindowSnapshot],
         session: CaptureOverlayController) {
        self.display = display
        self.windows = windows
        self.session = session
        super.init(frame: NSRect(origin: .zero, size: display.screenFrame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Display geometry this view covers (AppKit global coordinates).
    var screenFrame: CGRect { display.screenFrame }

    // MARK: - Tracking & cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        let cursor: NSCursor = session?.activeTool == .text ? .iBeam : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }

    /// Called by the session when the active tool changes: only the cursor
    /// shape follows a tool, so nothing has to be repainted.
    func toolDidChange() {
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Coordinate helpers

    private var globalOrigin: CGPoint {
        window?.frame.origin ?? display.screenFrame.origin
    }

    private func toGlobal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + globalOrigin.x, y: point.y + globalOrigin.y)
    }

    private func toLocal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - globalOrigin.x, y: point.y - globalOrigin.y)
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        toGlobal(convert(event.locationInWindow, from: nil))
    }

    /// The session selection clipped to this display, in view coordinates.
    private var localSelection: CGRect? {
        guard let selection = session?.selection else { return nil }
        let intersection = selection.intersection(display.screenFrame)
        guard !intersection.isNull, intersection.width >= 1, intersection.height >= 1 else { return nil }
        return CGRect(x: intersection.minX - display.screenFrame.minX,
                      y: intersection.minY - display.screenFrame.minY,
                      width: intersection.width,
                      height: intersection.height)
    }

    private var localHoverRect: CGRect? {
        guard let hoverWindowRect else { return nil }
        let intersection = hoverWindowRect.intersection(display.screenFrame)
        guard !intersection.isNull, intersection.width >= 1, intersection.height >= 1 else { return nil }
        return CGRect(x: intersection.minX - display.screenFrame.minX,
                      y: intersection.minY - display.screenFrame.minY,
                      width: intersection.width,
                      height: intersection.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. Frozen frame (cropped to the dirty rect: a selection drag or a
        // hover change repaints only the affected rectangles).
        drawFrozenFrame(in: context, dirtyRect: dirtyRect)

        let selectionRect = localSelection
        let hoverRect = selectionRect == nil ? localHoverRect : nil

        // 2. Dim mask. Only the selection is punched out: a hovered window is
        // outlined instead of lit, so nothing bright (or dark) ever travels
        // with the pointer.
        NSColor.black.withAlphaComponent(0.45).setFill()
        if let selectionRect {
            let mask = NSBezierPath(rect: bounds)
            mask.append(NSBezierPath(rect: selectionRect))
            mask.windingRule = .evenOdd
            mask.fill()
        } else {
            bounds.fill()
        }

        // 3. Hovered window outline.
        if let hoverRect {
            let outline = NSBezierPath(rect: hoverRect.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }

        // 4. Annotations live on the frozen pixels, below the selection chrome.
        if let selectionRect {
            drawAnnotations(in: context, clippedTo: selectionRect)
        }

        // 5. Selection border, handles and size badge.
        if let selectionRect {
            drawSelection(selectionRect)
        }
    }

    private func drawAnnotations(in context: CGContext, clippedTo rect: CGRect) {
        var items = session?.annotations ?? []
        if let inProgressItem {
            items.append(inProgressItem)
        }
        guard !items.isEmpty else { return }
        let mosaic = items.contains { $0.tool == .mosaic } ? mosaicSource() : nil
        AnnotationPainter.draw(items,
                               in: context,
                               origin: display.screenFrame.origin,
                               scale: 1,
                               canvasSize: display.screenFrame.size,
                               mosaic: mosaic,
                               clip: rect)
    }

    private func mosaicSource() -> CGImage? {
        if let mosaicCache { return mosaicCache }
        let image = MosaicGenerator.pixelated(display.image)
        mosaicCache = image
        return image
    }

    /// Global annotation bounds → local, padded, so a drag only repaints the
    /// stroke that moved (never the whole 5K frozen frame).
    private func annotationDirtyRect(for item: AnnotationItem) -> CGRect {
        annotationDirtyRect(at: item.bounds, padding: 4)
    }

    private func annotationDirtyRect(at global: CGPoint, radius: CGFloat) -> CGRect {
        annotationDirtyRect(at: CGRect(x: global.x - radius,
                                       y: global.y - radius,
                                       width: radius * 2,
                                       height: radius * 2),
                            padding: 4)
    }

    private func annotationDirtyRect(at globalRect: CGRect, padding: CGFloat) -> CGRect {
        globalRect
            .offsetBy(dx: -display.screenFrame.minX, dy: -display.screenFrame.minY)
            .insetBy(dx: -padding, dy: -padding)
            .intersection(bounds)
    }

    /// Pre-builds the pixelated frame when the mosaic tool is picked, so the
    /// first stroke does not stutter mid-drag. Pixelating a 5K frame is real work
    /// (once per display), so it runs off the main actor; `mosaicSource()` stays
    /// as the synchronous fallback when the user draws before it finishes.
    func prepareMosaic() {
        guard mosaicCache == nil, !isPreparingMosaic else { return }
        isPreparingMosaic = true
        let image = display.image
        // The outer Task inherits the main actor, so the code after the await is
        // back on MainActor without a nested MainActor.run — a `MainActor.run`
        // inside a detached task captures the weak `self` var and is a Swift 6
        // concurrency error.
        Task { [weak self] in
            let pixelated = await Task.detached(priority: .userInitiated) {
                MosaicGenerator.pixelated(image)
            }.value
            guard let self else { return }
            self.isPreparingMosaic = false
            if self.mosaicCache == nil {
                self.mosaicCache = pixelated
            }
        }
    }

    private func drawFrozenFrame(in context: CGContext, dirtyRect: NSRect) {
        let imageBounds = CGRect(x: 0, y: 0,
                                 width: CGFloat(display.image.width),
                                 height: CGFloat(display.image.height))
        let coversEverything = dirtyRect.isEmpty
            || (dirtyRect.minX <= bounds.minX && dirtyRect.maxX >= bounds.maxX
                && dirtyRect.minY <= bounds.minY && dirtyRect.maxY >= bounds.maxY)

        if !coversEverything {
            let scaleX = display.pixelScaleX
            let scaleY = display.pixelScaleY
            let sourceRect = CGRect(x: (dirtyRect.minX - bounds.minX) * scaleX,
                                    y: (bounds.maxY - dirtyRect.maxY) * scaleY,
                                    width: dirtyRect.width * scaleX,
                                    height: dirtyRect.height * scaleY)
                .integral
                .intersection(imageBounds)
            if !sourceRect.isNull, let part = display.image.cropping(to: sourceRect) {
                context.saveGState()
                context.interpolationQuality = .high
                context.draw(part, in: dirtyRect)
                context.restoreGState()
                return
            }
        }

        context.saveGState()
        context.interpolationQuality = .high
        context.draw(display.image, in: bounds)
        context.restoreGState()
    }

    private func drawSelection(_ rect: CGRect) {
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()

        NSColor.controlAccentColor.setStroke()
        let inner = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        inner.lineWidth = 1
        inner.stroke()

        for handle in SelectionHandle.allCases {
            let handleRect = handle.rect(in: rect, size: handleSize)
            let path = NSBezierPath(rect: handleRect)
            NSColor.white.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let sizeText = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        drawLabel(sizeText, at: CGPoint(x: rect.minX, y: rect.maxY + 6))
    }

    @discardableResult
    private func drawLabel(_ text: String, at point: CGPoint) -> CGRect {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        var rect = CGRect(x: point.x, y: point.y,
                          width: textSize.width + 10, height: textSize.height + 4)
        rect.origin.x = min(max(rect.minX, bounds.minX + 4), max(bounds.minX + 4, bounds.maxX - 4 - rect.width))
        rect.origin.y = min(max(rect.minY, bounds.minY + 4), max(bounds.minY + 4, bounds.maxY - 4 - rect.height))

        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 5, y: rect.minY + 2), withAttributes: attributes)
        return rect
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        guard session?.selection == nil else { return }
        updateHover(at: globalPoint(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        refreshHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let global = globalPoint(for: event)
        // Keyboard (Esc / ⌘Z / inline text) must land on the display that was
        // actually clicked, not only on the one that happened to be key.
        if window?.isKeyWindow != true {
            window?.makeKey()
            window?.makeFirstResponder(self)
        }
        // Double-click inside the frame always keeps the shot: copy and close,
        // exactly like every other screenshot tool — with an annotation tool
        // active too. A pending inline text edit is committed first so the
        // copied image cannot silently lose what was just typed.
        if event.clickCount >= 2,
           let selection = session?.selection, selection.contains(global) {
            endTextEditing(commit: true)
            inProgressItem = nil
            isErasing = false
            dragMode = .idle
            // A freehand tool commits a dot on the first click of the pair; that
            // dot is not what the user wants to keep, so it is rolled back.
            if let dotTime = lastClickDotTime,
               ProcessInfo.processInfo.systemUptime - dotTime < NSEvent.doubleClickInterval {
                session?.undoAnnotation()
            }
            lastClickDotTime = nil
            // "Keep the shot" means both halves: pasteboard for immediate use and
            // a file on disk (the double-click used to copy only, silently
            // dropping the screenshot the user thought was kept).
            session?.confirm(.copyAndSave)
            return
        }

        // Clicking anywhere commits a pending inline text edit first.
        endTextEditing(commit: true)

        if let tool = session?.activeTool {
            // Strokes outside the frame would be committed and then clipped
            // away, i.e. an invisible annotation: refuse them, and say why.
            guard let selection = session?.selection,
                  selection.insetBy(dx: -2, dy: -2).contains(global) else {
                CaptureToast.shared.show("请在选区内绘制（\(tool.displayName)）",
                                         symbol: "exclamationmark.circle",
                                         duration: 1.3)
                return
            }
            beginAnnotation(tool: tool, at: global)
            return
        }

        // Annotations lock the frame: moving / resizing would tear them loose.
        if session?.hasAnnotations == true {
            return
        }

        dragAnchor = global

        if let selection = session?.selection {
            if let handle = SelectionHandle.hitTest(global, in: selection, size: handleSize) {
                dragMode = .resizing(handle)
                dragStartSelection = selection
                return
            }
            if selection.insetBy(dx: -4, dy: -4).contains(global) {
                dragMode = .moving
                dragStartSelection = selection
                return
            }
        }

        dragMode = .dragging
        // Clearing the outline must repaint it, otherwise the old highlight
        // stays behind while the new selection is dragged over it.
        refreshHover(nil)
        session?.setSelection(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let global = globalPoint(for: event)

        if isErasing {
            session?.eraseAnnotation(at: global)
            setNeedsDisplay(annotationDirtyRect(at: global, radius: 24))
            return
        }

        if var item = inProgressItem {
            let previous = annotationDirtyRect(for: item)
            item.end = global
            if item.tool.usesFreehand {
                item.path.append(global)
            }
            inProgressItem = item
            setNeedsDisplay(previous.union(annotationDirtyRect(for: item)))
            return
        }

        switch dragMode {
        case .idle:
            break
        case .dragging:
            session?.setSelection(SelectionGeometry.normalized(dragAnchor, global))
        case .moving:
            let dx = global.x - dragAnchor.x
            let dy = global.y - dragAnchor.y
            session?.setSelection(dragStartSelection.offsetBy(dx: dx, dy: dy))
        case .resizing(let handle):
            session?.setSelection(SelectionGeometry.resized(dragStartSelection, handle: handle, to: global))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let global = globalPoint(for: event)

        if isErasing {
            isErasing = false
            return
        }

        if var item = inProgressItem {
            inProgressItem = nil
            // mouseDragged is not guaranteed to run for the final location, so
            // the last sample is appended here before committing.
            item.end = global
            if item.tool.usesFreehand, item.path.last != global {
                item.path.append(global)
            }
            // A click without a drag is not a shape (freehand dots are kept), and
            // a flat / zero-size box would only lock the frame invisibly.
            let distance = AnnotationMath.distance(from: item.start, to: item.end)
            if item.isMeaningful {
                session?.commitAnnotation(item)
                lastClickDotTime = item.tool.usesFreehand && distance <= 2
                    ? ProcessInfo.processInfo.systemUptime
                    : nil
            }
            return
        }

        let mode = dragMode
        dragMode = .idle

        switch mode {
        case .dragging:
            let distance = hypot(global.x - dragAnchor.x, global.y - dragAnchor.y)
            if distance < 3 {
                // A plain click adopts the window under the cursor, if any.
                if let hit = WindowHitTester.window(at: global, in: windows) {
                    session?.setSelection(hit.rect)
                    session?.selectionCommitted()
                } else {
                    session?.setSelection(nil)
                }
            } else if let selection = session?.selection, selection.width >= 3, selection.height >= 3 {
                session?.selectionCommitted()
            }
        case .moving, .resizing:
            if let selection = session?.selection, selection.width >= 3, selection.height >= 3 {
                session?.selectionCommitted()
            }
        case .idle:
            break
        }

        if session?.selection == nil {
            refreshHover(WindowHitTester.window(at: global, in: windows)?.rect)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        endTextEditing(commit: false)
        session?.cancel()
    }

    // MARK: - Annotations

    private func beginAnnotation(tool: AnnotationTool, at global: CGPoint) {
        // A tool click must never inherit a half-finished selection drag.
        dragMode = .idle
        switch tool {
        case .text:
            beginTextEditing(at: global)
        case .number:
            session?.commitNumberAnnotation(at: global)
        case .eraser:
            isErasing = true
            session?.eraseAnnotation(at: global)
        case .rectangle, .ellipse, .arrow, .pen, .highlighter, .mosaic:
            let style = session?.style ?? AnnotationStyle()
            let item = AnnotationItem(tool: tool,
                                      start: global,
                                      end: global,
                                      path: tool.usesFreehand ? [global] : [],
                                      color: style.color,
                                      lineWidth: style.lineWidth,
                                      alpha: style.highlighterAlpha)
            inProgressItem = item
            setNeedsDisplay(annotationDirtyRect(for: item))
        }
    }

    // MARK: - Inline text

    /// Concrete AppKit font for the inline editor — the same family/size the
    /// painter will use, so typing looks exactly like the committed annotation.
    private func textFieldFont(_ style: AnnotationStyle) -> NSFont {
        if !style.font.name.isEmpty, let font = NSFont(name: style.font.name, size: style.fontSize) {
            return font
        }
        return .systemFont(ofSize: style.fontSize)
    }

    private func beginTextEditing(at global: CGPoint) {
        let local = toLocal(global)
        let style = session?.style ?? AnnotationStyle()
        let fontSize = style.fontSize
        let height = (fontSize * 1.5).rounded()
        // The field is vertically centred on the annotation baseline.
        let field = NSTextField(frame: NSRect(x: local.x,
                                              y: local.y - fontSize * 0.4,
                                              width: 220,
                                              height: height))
        // No box, no fill: only the text and the caret are visible, so the
        // frozen screenshot stays unobstructed while typing.
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = textFieldFont(style)
        field.textColor = textColor(style)
        field.placeholderString = "输入文字，回车确认"
        field.delegate = self
        addSubview(field)
        textEditor = field
        textOrigin = global
        window?.makeFirstResponder(field)
        applyStyleToTextEditor(style)

        // The field editor can appear one run-loop turn later: re-apply then so
        // the clear background and the coloured caret are guaranteed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.textEditor != nil else { return }
            self.applyStyleToTextEditor(self.session?.style ?? AnnotationStyle())
        }
    }

    private func textColor(_ style: AnnotationStyle) -> NSColor {
        NSColor(srgbRed: style.color.red,
                green: style.color.green,
                blue: style.color.blue,
                alpha: 1)
    }

    /// Applies colour / font / size changes to a live inline editor: the caret,
    /// the already typed glyphs and the next keystroke all switch immediately.
    func applyStyleToTextEditor(_ style: AnnotationStyle) {
        guard let field = textEditor else { return }
        let font = textFieldFont(style)
        let color = textColor(style)

        // Re-anchor on the original baseline: the frame height follows the size.
        let local = toLocal(textOrigin)
        let height = (style.fontSize * 1.5).rounded()
        field.frame = NSRect(x: field.frame.minX,
                             y: local.y - style.fontSize * 0.4,
                             width: field.frame.width,
                             height: height)
        field.font = font
        field.textColor = color

        // While editing, the field editor owns the visible text: its background
        // must stay clear and its caret takes the annotation colour.
        if let editor = field.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.font = font
            editor.textColor = color
            editor.insertionPointColor = color
            editor.typingAttributes = [
                .font: font,
                .foregroundColor: color,
            ]
        }
        resizeTextEditor()
    }

    /// Grows the editor with the typed text (a 40 pt annotation easily exceeds
    /// the initial frame), clamped to the right edge of the selection.
    private func resizeTextEditor() {
        guard let field = textEditor, let font = field.font else { return }
        let measured = ceil((field.stringValue as NSString).size(withAttributes: [.font: font]).width)
        let limit = localSelection.map { max(160, $0.maxX - field.frame.minX) } ?? 640
        let width = min(max(measured + 24, 160), limit)
        guard abs(width - field.frame.width) > 2 else { return }
        field.frame.size.width = width
    }

    /// Commits (or drops) the inline editor. Idempotent: the field is detached
    /// before the responder change, which would otherwise re-enter this method.
    private func endTextEditing(commit: Bool) {
        guard let field = textEditor else { return }
        textEditor = nil
        let text = field.stringValue
        let origin = textOrigin
        field.delegate = nil
        // The field editor is shared app-wide: never leak our custom caret /
        // transparent background into the next text field that uses it.
        if let editor = field.currentEditor() as? NSTextView {
            editor.drawsBackground = true
            // The field editor is shared by every text field of the app: leaving
            // a clear background behind would make the settings fields transparent.
            editor.backgroundColor = .textBackgroundColor
            editor.insertionPointColor = .textColor
        }
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if commit {
            session?.commitTextAnnotation(text, at: origin)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            session?.cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            session?.confirm(.save)
        case kVK_LeftArrow:
            nudge(dx: event.modifierFlags.contains(.shift) ? -10 : -1, dy: 0)
        case kVK_RightArrow:
            nudge(dx: event.modifierFlags.contains(.shift) ? 10 : 1, dy: 0)
        case kVK_UpArrow:
            nudge(dx: 0, dy: event.modifierFlags.contains(.shift) ? 10 : 1)
        case kVK_DownArrow:
            nudge(dx: 0, dy: event.modifierFlags.contains(.shift) ? -10 : -1)
        default:
            super.keyDown(with: event)
        }
    }

    /// Called from CaptureOverlayWindow.performKeyEquivalent (⌘C / ⌘S).
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard session?.selection != nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            session?.confirm(.copy)
            return true
        case "s":
            session?.confirm(.save)
            return true
        case "z":
            if flags.contains(.shift) {
                session?.redoAnnotation()
            } else {
                session?.undoAnnotation()
            }
            return true
        default:
            return false
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        // Annotations are anchored to the frame: nudging would detach them.
        guard session?.hasAnnotations != true, let selection = session?.selection else { return }
        session?.setSelection(selection.offsetBy(dx: dx, dy: dy))
    }

    // MARK: - Responder-chain actions
    //
    // The invisible main menu owns ⌘C / ⌘Z (for text fields). Implementing the
    // matching actions here makes the shortcuts work in the overlay no matter
    // whether the window or the menu sees the key equivalent first. While the
    // inline text editor is first responder, its own field editor handles them.

    @objc func undo(_ sender: Any?) {
        session?.undoAnnotation()
    }

    @objc func redo(_ sender: Any?) {
        session?.redoAnnotation()
    }

    @objc func copy(_ sender: Any?) {
        session?.confirm(.copy)
    }

    // MARK: - Hover updates (partial redraw only)

    private func updateHover(at global: CGPoint) {
        refreshHover(WindowHitTester.window(at: global, in: windows)?.rect)
    }

    /// Single place that changes `hoverWindowRect`. Only the outlines that
    /// actually changed are repainted: the dim mask is uniform, so "no outline
    /// before, none after" means the screen is already correct — never fall back
    /// to a full 5K redraw.
    private func refreshHover(_ newRect: CGRect?) {
        guard newRect != hoverWindowRect else { return }
        let oldLocal = localHoverRect
        hoverWindowRect = newRect
        let newLocal = localHoverRect
        var dirty: CGRect?
        for rect in [oldLocal, newLocal].compactMap({ $0 }) {
            dirty = dirty.map { $0.union(rect) } ?? rect
        }
        guard let dirty else { return }
        setNeedsDisplay(dirty.insetBy(dx: -4, dy: -4))
    }

}

extension CaptureOverlayView: NSTextFieldDelegate {
    /// Enter commits, Esc drops, anything else stays with the field editor (so
    /// Chinese IME candidates keep working).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endTextEditing(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        resizeTextEditor()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Click elsewhere / Tab: keep whatever was typed.
        endTextEditing(commit: true)
    }
}
