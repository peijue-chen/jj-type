//
//  CaptureToolbarController.swift
//  jj-type
//
//  Floating toolbar shown next to a confirmed selection: 9 annotation tools,
//  undo/redo, a style row (6 colours + 3 widths) and the actions
//  recognize / pin / save / copy / close. It sits *above* the overlay (same
//  level would let a canvas click raise the full-screen overlay over the
//  toolbar and hide it), never takes focus, and shows its own hover hints
//  because an NSPanel that never becomes key drops system tooltips.
//

import AppKit
import CoreGraphics

final class CaptureToolbarController {
    enum Action {
        case save
        case copy
        /// Double-click inside the frame: keep the shot — copy AND save.
        case copyAndSave
        case close
        case recognize
        case pin
        case qr
    }

    var onAction: ((Action) -> Void)?
    var onToolChanged: ((AnnotationTool?) -> Void)?
    var onStyleChanged: ((AnnotationStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let stack = NSStackView()
    private let toolRow = NSStackView()
    private let styleRow = NSStackView()
    /// Tool-specific options: font + size for the text tool, alpha for the
    /// highlighter. Hidden entirely while a tool without options is active.
    private let optionRow = NSStackView()
    private let fontGroup = NSStackView()
    private let alphaGroup = NSStackView()
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private let widthControl = NSSegmentedControl(labels: AnnotationPalette.widthNames,
                                                  trackingMode: .selectOne,
                                                  target: nil,
                                                  action: nil)
    /// Segmented, not a pop-up: a pop-up menu sits at level 101 and would be
    /// drawn *under* this panel (screenSaver + 2).
    private let fontControl = NSSegmentedControl(labels: AnnotationFont.options.map(\.displayName),
                                                 trackingMode: .selectOne,
                                                 target: nil,
                                                 action: nil)
    private let fontSizeControl = NSSegmentedControl(labels: AnnotationPalette.fontSizeNames,
                                                     trackingMode: .selectOne,
                                                     target: nil,
                                                     action: nil)
    private let alphaSlider = NSSlider(value: 0.35,
                                       minValue: Double(AnnotationPalette.alphaRange.lowerBound),
                                       maxValue: Double(AnnotationPalette.alphaRange.upperBound),
                                       target: nil,
                                       action: nil)
    private let alphaLabel = NSTextField(labelWithString: "透明度")
    private var undoButton: NSButton?
    private var redoButton: NSButton?

    private var didBuild = false
    private var lastAnchor: CGRect = .zero
    private var activeTool: AnnotationTool?
    private var style = AnnotationStyle()
    private var canUndo = false
    private var canRedo = false

    // MARK: - Hover hints (own implementation, see file header)

    private var tooltipPanel: NSPanel?
    private var tooltipLabel: NSTextField?
    private var tooltipTask: Task<Void, Never>?
    private weak var hoveredButton: NSButton?

    /// Window levels: the toolbar must stay above the overlay, the hint above
    /// the toolbar.
    static let panelLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 2)
    private static let tooltipLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 3)

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 68),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.level = Self.panelLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    func show(anchor: CGRect) {
        buildIfNeeded()
        lastAnchor = anchor
        layoutPanel()
        panel.orderFrontRegardless()
    }

    func hide() {
        hideTooltip()
        panel.orderOut(nil)
    }

    /// Pushes the session state into the toolbar (single source of truth lives
    /// in CaptureOverlayController).
    func apply(tool: AnnotationTool?, style: AnnotationStyle, canUndo: Bool, canRedo: Bool) {
        let previousTool = activeTool
        activeTool = tool
        self.style = style
        self.canUndo = canUndo
        self.canRedo = canRedo
        guard didBuild else { return }
        refreshState()
        // Only the tool switch changes the panel's shape; a colour / alpha tick
        // must not move the panel out from under the pointer.
        if panel.isVisible, previousTool != tool {
            layoutPanel()
        }
    }

    // MARK: - Layout

    private func layoutPanel() {
        styleRow.isHidden = activeTool == nil
        refreshOptionRow()
        stack.needsLayout = true
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        panel.setContentSize(size)
        background.frame = NSRect(origin: .zero, size: size)
        background.layoutSubtreeIfNeeded()

        let anchor = lastAnchor
        let visible = Self.screen(for: anchor)?.visibleFrame ?? anchor

        var x = anchor.maxX - size.width
        var y = anchor.minY - 8 - size.height
        if y < visible.minY + 8 {
            y = anchor.maxY + 8
        }
        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        y = min(max(y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))

        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    /// Screen holding the selection centre; falls back to the largest overlap
    /// (a selection can straddle two displays or sit in the gap between them).
    private static func screen(for anchor: CGRect) -> NSScreen? {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        if let containing = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(anchor)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) {
                best = (screen, area)
            }
        }
        return best?.screen ?? NSScreen.main
    }

    private func buildIfNeeded() {
        guard !didBuild else { return }
        didBuild = true

        toolRow.orientation = .horizontal
        toolRow.spacing = 4
        toolRow.alignment = .centerY
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            let button = makeIconButton(symbol: tool.symbolName,
                                        tooltip: tool.hint,
                                        action: #selector(toolClicked(_:)))
            button.tag = index
            button.setButtonType(.toggle)
            toolButtons[tool] = button
            toolRow.addArrangedSubview(button)
        }
        toolRow.addArrangedSubview(makeSeparator())

        let undo = makeIconButton(symbol: "arrow.uturn.backward",
                                  tooltip: "撤销 ⌘Z",
                                  action: #selector(undoClicked))
        let redo = makeIconButton(symbol: "arrow.uturn.forward",
                                  tooltip: "重做 ⇧⌘Z",
                                  action: #selector(redoClicked))
        undoButton = undo
        redoButton = redo
        toolRow.addArrangedSubview(undo)
        toolRow.addArrangedSubview(redo)
        toolRow.addArrangedSubview(makeSeparator())
        toolRow.addArrangedSubview(makeIconButton(symbol: "text.viewfinder",
                                                  tooltip: "识别文字 — OCR 后复制到剪贴板",
                                                  action: #selector(recognizeClicked)))
        toolRow.addArrangedSubview(makeIconButton(symbol: "qrcode",
                                                  tooltip: "识别二维码 — 解析图中二维码并复制",
                                                  action: #selector(qrClicked)))
        toolRow.addArrangedSubview(makeIconButton(symbol: "pin",
                                                  tooltip: "钉住 — 贴到屏幕上常驻",
                                                  action: #selector(pinClicked)))
        toolRow.addArrangedSubview(makeIconButton(symbol: "square.and.arrow.down",
                                                  tooltip: "保存 ⌘S — 存到图片目录",
                                                  action: #selector(saveClicked)))
        toolRow.addArrangedSubview(makeIconButton(symbol: "doc.on.doc",
                                                  tooltip: "复制 ⌘C — 复制到剪贴板",
                                                  action: #selector(copyClicked)))
        toolRow.addArrangedSubview(makeIconButton(symbol: "xmark",
                                                  tooltip: "取消 Esc",
                                                  action: #selector(closeClicked)))

        styleRow.orientation = .horizontal
        styleRow.spacing = 6
        styleRow.alignment = .centerY
        for (index, color) in AnnotationColor.palette.enumerated() {
            let button = makeColorButton(color, index: index)
            colorButtons.append(button)
            styleRow.addArrangedSubview(button)
        }
        styleRow.addArrangedSubview(makeSeparator())
        widthControl.target = self
        widthControl.action = #selector(widthChanged(_:))
        widthControl.segmentStyle = .rounded
        widthControl.selectedSegment = style.widthIndex
        styleRow.addArrangedSubview(widthControl)

        optionRow.orientation = .horizontal
        optionRow.spacing = 6
        optionRow.alignment = .centerY
        optionRow.addArrangedSubview(fontGroup)
        optionRow.addArrangedSubview(alphaGroup)

        fontGroup.orientation = .horizontal
        fontGroup.spacing = 6
        fontGroup.alignment = .centerY
        fontControl.target = self
        fontControl.action = #selector(fontChanged(_:))
        fontControl.segmentStyle = .rounded
        fontControl.controlSize = .small
        fontControl.selectedSegment = style.fontIndex
        fontSizeControl.target = self
        fontSizeControl.action = #selector(fontSizeChanged(_:))
        fontSizeControl.segmentStyle = .rounded
        fontSizeControl.controlSize = .small
        fontSizeControl.selectedSegment = style.fontSizeIndex
        fontGroup.addArrangedSubview(makeOptionCaption("字体"))
        fontGroup.addArrangedSubview(fontControl)
        fontGroup.addArrangedSubview(makeOptionCaption("字号"))
        fontGroup.addArrangedSubview(fontSizeControl)

        alphaGroup.orientation = .horizontal
        alphaGroup.spacing = 6
        alphaGroup.alignment = .centerY
        alphaLabel.font = .systemFont(ofSize: 11)
        alphaLabel.textColor = .labelColor
        alphaSlider.target = self
        alphaSlider.action = #selector(alphaChanged(_:))
        alphaSlider.isContinuous = true
        alphaSlider.controlSize = .small
        alphaSlider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            alphaSlider.widthAnchor.constraint(equalToConstant: 120),
        ])
        alphaGroup.addArrangedSubview(alphaLabel)
        alphaGroup.addArrangedSubview(alphaSlider)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(toolRow)
        stack.addArrangedSubview(styleRow)
        stack.addArrangedSubview(optionRow)

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        refreshState()
        background.layoutSubtreeIfNeeded()
    }

    private func refreshState() {
        for (tool, button) in toolButtons {
            let isOn = tool == activeTool
            button.state = isOn ? .on : .off
            button.contentTintColor = isOn ? Theme.accent : .labelColor
        }
        for (index, button) in colorButtons.enumerated() {
            let selected = index == style.colorIndex
            // Accent ring: a white ring would vanish on the white swatch.
            button.layer?.borderWidth = selected ? 2 : 0
            button.layer?.borderColor = selected ? Theme.accent.cgColor : nil
        }
        widthControl.selectedSegment = style.widthIndex
        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo
        styleRow.isHidden = activeTool == nil
        refreshOptionRow()
    }

    private func makeIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = ToolbarHoverButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        // No system toolTip: a panel that never becomes key drops it.
        button.contentTintColor = .labelColor
        button.onHoverChange = { [weak self, weak button] inside in
            guard let self, let button else { return }
            if inside {
                self.scheduleTooltip(for: button, text: tooltip)
            } else {
                self.dismissTooltip(for: button)
            }
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    // MARK: - Hover hints

    private func scheduleTooltip(for button: NSButton, text: String) {
        hoveredButton = button
        tooltipTask?.cancel()
        tooltipTask = Task { [weak self, weak button] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled, let self, let button, self.hoveredButton === button else { return }
            self.presentTooltip(for: button, text: text)
        }
    }

    private func dismissTooltip(for button: NSButton) {
        guard hoveredButton === button else { return }
        hoveredButton = nil
        hideTooltip()
    }

    private func hideTooltip() {
        tooltipTask?.cancel()
        tooltipTask = nil
        tooltipPanel?.orderOut(nil)
    }

    private func presentTooltip(for button: NSButton, text: String) {
        let panel = tooltipPanel ?? makeTooltipPanel()
        guard let label = tooltipLabel else { return }

        label.stringValue = text
        let font = label.font ?? NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let padding: CGFloat = 9
        let size = NSSize(width: min(360, textWidth) + padding * 2, height: 26)
        panel.setContentSize(size)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        label.frame = NSRect(x: padding,
                             y: (size.height - 16) / 2,
                             width: size.width - padding * 2,
                             height: 16)

        guard let buttonWindow = button.window else { return }
        let onScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = buttonWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? onScreen
        var x = onScreen.midX - size.width / 2
        var y = onScreen.minY - 6 - size.height
        if y < visible.minY + 4 {
            y = onScreen.maxY + 6
        }
        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    private func makeTooltipPanel() -> NSPanel {
        let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 26),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        created.level = Self.tooltipLevel
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        created.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        created.contentView = effect

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        effect.addSubview(label)
        tooltipLabel = label
        tooltipPanel = created
        return created
    }

    private func makeColorButton(_ color: AnnotationColor, index: Int) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(colorClicked(_:)))
        button.isBordered = false
        button.tag = index
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(srgbRed: color.red,
                                                green: color.green,
                                                blue: color.blue,
                                                alpha: 1).cgColor
        button.layer?.cornerRadius = 8
        button.layer?.borderColor = NSColor.white.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 16),
            button.heightAnchor.constraint(equalToConstant: 16),
        ])
        return button
    }

    private func makeOptionCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Shows exactly the options the active tool understands: font + size for
    /// text, transparency for the highlighter, nothing for the rest.
    private func refreshOptionRow() {
        let isText = activeTool == .text
        let isHighlighter = activeTool == .highlighter
        optionRow.isHidden = !(isText || isHighlighter)
        fontGroup.isHidden = !isText
        alphaGroup.isHidden = !isHighlighter
        // Text size replaces stroke width: the width would only change the
        // inline field's frame, not the glyphs.
        widthControl.isHidden = isText

        fontControl.selectedSegment = min(max(style.fontIndex, 0), AnnotationFont.options.count - 1)
        fontSizeControl.selectedSegment = min(max(style.fontSizeIndex, 0),
                                              AnnotationPalette.fontSizes.count - 1)
        let percentage = Int((style.highlighterAlpha * 100).rounded())
        alphaLabel.stringValue = "透明度 \(percentage)%"
        alphaSlider.doubleValue = Double(style.highlighterAlpha)
    }

    private func makeSeparator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 18),
        ])
        return view
    }

    // MARK: - Actions

    @objc private func toolClicked(_ sender: NSButton) {
        hideTooltip()
        let tools = AnnotationTool.allCases
        guard sender.tag >= 0, sender.tag < tools.count else { return }
        let tool = tools[sender.tag]
        // Toggle: clicking the active tool returns to selection editing.
        onToolChanged?(tool == activeTool ? nil : tool)
    }

    @objc private func colorClicked(_ sender: NSButton) {
        var updated = style
        updated.colorIndex = sender.tag
        onStyleChanged?(updated)
    }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        var updated = style
        updated.widthIndex = max(0, sender.selectedSegment)
        onStyleChanged?(updated)
    }

    @objc private func fontChanged(_ sender: NSSegmentedControl) {
        var updated = style
        updated.fontIndex = max(0, sender.selectedSegment)
        onStyleChanged?(updated)
    }

    @objc private func fontSizeChanged(_ sender: NSSegmentedControl) {
        var updated = style
        updated.fontSizeIndex = max(0, sender.selectedSegment)
        onStyleChanged?(updated)
    }

    @objc private func alphaChanged(_ sender: NSSlider) {
        var updated = style
        updated.highlighterAlpha = CGFloat(sender.doubleValue)
        onStyleChanged?(updated)
    }

    @objc private func undoClicked() {
        onUndo?()
    }

    @objc private func redoClicked() {
        onRedo?()
    }

    @objc private func saveClicked() {
        onAction?(.save)
    }

    @objc private func copyClicked() {
        onAction?(.copy)
    }

    @objc private func recognizeClicked() {
        onAction?(.recognize)
    }

    @objc private func qrClicked() {
        onAction?(.qr)
    }

    @objc private func pinClicked() {
        onAction?(.pin)
    }

    @objc private func closeClicked() {
        onAction?(.close)
    }
}

/// Button that reports hover state so the toolbar can show its own hint.
/// `activeAlways` keeps it working while another app owns the menu bar.
final class ToolbarHoverButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}
