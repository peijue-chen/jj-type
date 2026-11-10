//
//  EyedropperController.swift
//  jj-type
//
//  Screen color picker: ⌥P (configurable) starts a session — a loupe panel
//  follows the cursor (offset, so clicks never hit the loupe), showing an
//  8×-magnified pixel grid sampled via CGDisplayCreateImage (needs the Screen
//  Recording grant, gated by AppDelegate). Tracking is THREE-layered: global
//  mouseMoved monitor (instant, other apps' windows), local mouseMoved
//  monitor (moves routed to our own windows never reach the global one) and
//  a 30 fps cursor poll (catch-all for apps with their own event taps) —
//  sampling only fires when the cursor actually moved. Click or ⏎ picks and
//  copies (HEX by default, Space toggles RGB), Esc cancels. Recent picks
//  persist as a small swatch history.
//
//  Coordinate note: the panel is positioned in AppKit (bottom-left) space;
//  sampling converts to CoreGraphics (top-left) per screen before cropping.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

final class EyedropperController {
    static let shared = EyedropperController()

    private let panel: NSPanel
    private let zoomView = EyedropperZoomView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "点击取色 · 空格切换格式 · Esc 取消")
    private let historyRow = NSStackView()
    private var monitors: [Any] = []
    /// Safety net for the global-monitor blind spots: moves routed to OUR
    /// own windows (app active) or swallowed by apps with their own event
    /// taps never reach a GLOBAL monitor — the poll keeps the loupe tracking.
    private var pollTimer: Timer?
    private var lastSampledPoint = NSPoint(x: -1, y: -1)

    private var isRunning = false
    private var useRGB = false
    private var currentColor: NSColor?
    private let store = SettingsStore()

    private static let loupeSize: CGFloat = 160
    /// Sample region in points (26 cells across at any backing scale look
    /// right in a 160 pt loupe).
    private static let samplePoints: CGFloat = 13
    private static let historyLimit = 12

    private init() {
        let width = Self.loupeSize + 24
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 260),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        panel.contentView = background

        zoomView.wantsLayer = true
        zoomView.layer?.cornerRadius = 8
        zoomView.layer?.masksToBounds = true
        zoomView.translatesAutoresizingMaskIntoConstraints = false

        infoLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        infoLabel.textColor = .labelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        historyRow.orientation = .horizontal
        historyRow.spacing = 6
        historyRow.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(zoomView)
        background.addSubview(infoLabel)
        background.addSubview(hintLabel)
        background.addSubview(historyRow)
        NSLayoutConstraint.activate([
            zoomView.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            zoomView.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            zoomView.widthAnchor.constraint(equalToConstant: Self.loupeSize),
            zoomView.heightAnchor.constraint(equalToConstant: Self.loupeSize),

            infoLabel.topAnchor.constraint(equalTo: zoomView.bottomAnchor, constant: 8),
            infoLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),

            historyRow.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 8),
            historyRow.centerXAnchor.constraint(equalTo: background.centerXAnchor),

            hintLabel.topAnchor.constraint(equalTo: historyRow.bottomAnchor, constant: 8),
            hintLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Session

    func begin() {
        guard !isRunning else { return }
        isRunning = true
        rebuildHistorySwatches()
        installMonitors()
        panel.orderFrontRegardless()
        lastSampledPoint = NSEvent.mouseLocation
        sample(at: lastSampledPoint)
        startPolling()
    }

    private func end() {
        removeMonitors()
        pollTimer?.invalidate()
        pollTimer = nil
        panel.orderOut(nil)
        isRunning = false
        currentColor = nil
    }

    // MARK: - Monitors

    private func installMonitors() {
        let moved = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged,
                                                                  .otherMouseDragged]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.sample(at: NSEvent.mouseLocation) }
        }
        // Moves delivered to OUR windows go to the local stream, never the
        // global one — mirror them or the loupe freezes over JJType windows.
        let localMoved = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged,
                                                                      .otherMouseDragged]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.sample(at: NSEvent.mouseLocation) }
            return event
        }
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.pick() }
        }
        let localDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.pick() }
            return nil // the loupe panel consumed the click
        }
        let key = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) }
        }
        let localKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) }
            return nil
        }
        monitors = [moved, localMoved, down, localDown, key, localKey].compactMap { $0 }
    }

    /// 30 fps cursor poll — samples ONLY when the location actually moved
    /// (>0.25 pt), so idle cost is negligible. This is the catch-all that
    /// makes the loupe follow in every case the monitors miss.
    private func startPolling() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                let point = NSEvent.mouseLocation
                if abs(point.x - self.lastSampledPoint.x) > 0.25 ||
                    abs(point.y - self.lastSampledPoint.y) > 0.25 {
                    self.sample(at: point)
                }
            }
        }
        // .common keeps the poll alive while a menu is open or during event
        // tracking (drag loops) — .default-mode timers pause in both.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func handleKey(_ event: NSEvent) {
        switch event.keyCode {
        case UInt16(kVK_Escape):
            end()
        case UInt16(kVK_Space):
            useRGB.toggle()
            refreshInfoLabel()
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            pick()
        default:
            break
        }
    }

    // MARK: - Sampling

    private func sample(at point: NSPoint) {
        lastSampledPoint = point
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                  as? CGDirectDisplayID else { return }

        // AppKit (bottom-left) → CG (top-left) within this screen, then crop a
        // square around the cursor in POINTS (backing scale is applied by the API).
        let size = Self.samplePoints
        let cgX = point.x - screen.frame.origin.x - size / 2
        let cgY = screen.frame.maxY - point.y - size / 2
        let rect = CGRect(x: cgX, y: cgY, width: size, height: size)

        guard let image = CGDisplayCreateImage(displayID, rect: rect) else {
            return
        }
        zoomView.update(sample: image, cells: Int(size))
        let rep = NSBitmapImageRep(cgImage: image)
        currentColor = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        refreshInfoLabel()
        positionPanel(for: point, in: screen)
    }

    private func refreshInfoLabel() {
        guard let color = currentColor?.usingColorSpace(.deviceRGB) else {
            infoLabel.stringValue = " "
            return
        }
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        infoLabel.stringValue = useRGB
            ? String(format: "rgb(%d, %d, %d)", r, g, b)
            : String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Loupe sits offset from the cursor (never under it — clicks must land on
    /// the color, not on the loupe), flipping sides near screen edges.
    private func positionPanel(for point: NSPoint, in screen: NSScreen) {
        let visible = screen.visibleFrame
        let offset: CGFloat = 28
        var origin = NSPoint(x: point.x + offset, y: point.y + offset)
        let size = panel.frame.size
        if origin.x + size.width > visible.maxX { origin.x = point.x - offset - size.width }
        if origin.y + size.height > visible.maxY { origin.y = point.y - offset - size.height }
        origin.x = max(origin.x, visible.minX + 4)
        origin.y = max(origin.y, visible.minY + 4)
        panel.setFrameOrigin(origin)
    }

    // MARK: - Pick / history

    private func pick() {
        guard isRunning else { return }
        guard let color = currentColor?.usingColorSpace(.deviceRGB) else { end(); return }
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        let value = useRGB
            ? String(format: "rgb(%d, %d, %d)", r, g, b)
            : String(format: "#%02X%02X%02X", r, g, b)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        store.recordColorHistory(value)
        CaptureToast.shared.show("已复制 \(value)", symbol: "eyedropper")
        end()
    }

    private func rebuildHistorySwatches() {
        historyRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, value) in store.colorHistory.enumerated() {
            let swatch = HistorySwatchButton(hex: value)
            swatch.target = self
            swatch.action = #selector(historySwatchClicked(_:))
            swatch.tag = index
            historyRow.addArrangedSubview(swatch)
        }
        historyRow.isHidden = store.colorHistory.isEmpty
    }

    @objc private func historySwatchClicked(_ sender: NSButton) {
        let history = store.colorHistory
        guard history.indices.contains(sender.tag) else { return }
        let value = history[sender.tag]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        CaptureToast.shared.show("已复制 \(value)", symbol: "eyedropper")
        end()
    }
}

/// Pixelated magnifier: nearest-neighbour draw of the sampled CGImage plus a
/// cell grid and a center crosshair over the pixel being picked.
private final class EyedropperZoomView: NSView {
    private var sample: CGImage?
    private var cells = 13

    func update(sample: CGImage, cells: Int) {
        self.sample = sample
        self.cells = max(1, cells)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let sample else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: sample, size: bounds.size).draw(in: bounds)

        // Cell grid (13 divisions regardless of backing scale).
        let step = bounds.width / CGFloat(cells)
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        for index in 0...cells {
            let offset = CGFloat(index) * step
            path.move(to: NSPoint(x: offset, y: 0))
            path.line(to: NSPoint(x: offset, y: bounds.maxY))
            path.move(to: NSPoint(x: 0, y: offset))
            path.line(to: NSPoint(x: bounds.maxX, y: offset))
        }
        path.stroke()

        // Center crosshair over the pixel under the cursor.
        NSColor.systemRed.setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1.5
        cross.move(to: NSPoint(x: bounds.midX - 8, y: bounds.midY))
        cross.line(to: NSPoint(x: bounds.midX + 8, y: bounds.midY))
        cross.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 8))
        cross.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 8))
        cross.stroke()
    }
}

/// One small clickable color square for the history row.
private final class HistorySwatchButton: NSButton {
    init(hex: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        bezelStyle = .texturedRounded
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.3).cgColor
        layer?.borderWidth = 1
        let color = Self.parse(hex) ?? Theme.accent
        layer?.backgroundColor = color.cgColor
        toolTip = hex
    }

    /// Accepts both "#RRGGBB" and "rgb(r, g, b)".
    private static func parse(_ value: String) -> NSColor? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.count == 6,
           trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdefABCDEF#").inverted) == nil {
            let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
            guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
            return NSColor(red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                           blue: CGFloat(rgb & 0xFF) / 255.0,
                           alpha: 1)
        }
        // rgb(r, g, b)
        let parts = trimmed
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return NSColor(red: CGFloat(parts[0]) / 255.0,
                       green: CGFloat(parts[1]) / 255.0,
                       blue: CGFloat(parts[2]) / 255.0,
                       alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
