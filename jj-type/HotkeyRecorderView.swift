//
//  HotkeyRecorderView.swift
//  jj-type
//
//  Records a global-hotkey combination from keyboard input.
//

import AppKit

final class HotkeyRecorderView: NSView {
    var onHotkeyChanged: ((Hotkey) -> Void)?
    /// Only fired when `allowsClearing` is on: ⌫ removes the binding instead of
    /// recording a new one (the built-in actions always need a combo).
    var onHotkeyCleared: (() -> Void)?

    private let label: NSTextField
    private let valueField = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let allowsClearing: Bool
    private var hotkey: Hotkey?
    /// Last accepted binding; restored when the controller rejects a candidate.
    private var acceptedHotkey: Hotkey?

    private static let defaultHint = "点击后按下新快捷键"

    init(label text: String, hotkey: Hotkey?, allowsClearing: Bool = false) {
        self.hotkey = hotkey
        self.acceptedHotkey = hotkey
        self.allowsClearing = allowsClearing
        self.label = NSTextField(labelWithString: text)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        // Full auto-layout citizen (It9 real fix): without an intrinsic height the
        // enclosing stack view treated this view as clay — one instance ballooned to
        // 220pt, the other was crushed to 0pt and became invisible.
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        // Explicit width: an NSView has no intrinsic width, and both hosts (stack
        // view and grid view) would otherwise leave it ambiguous.
        widthAnchor.constraint(equalToConstant: 320).isActive = true
        setup()
        refreshDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        label.font = .systemFont(ofSize: 13)
        valueField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        valueField.alignment = .center
        valueField.textColor = .controlAccentColor
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.stringValue = allowsClearing ? "\(Self.defaultHint)，⌫ 清除" : Self.defaultHint

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        let row = NSStackView(views: [label, valueField])
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    override var acceptsFirstResponder: Bool { true }

    /// Plain NSViews never become first responder on click by default — that was
    /// why only whichever recorder happened to hold focus could record (B1 fix).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        return true
    }

    override func resignFirstResponder() -> Bool {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        return true
    }

    override func drawFocusRingMask() {
        // Keep the rounded focus ring aligned with the border.
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func keyDown(with event: NSEvent) {
        // Ignore pure Esc (used to cancel recording) and bare modifier presses.
        guard event.keyCode != 53 else { return }
        // ⌫ / ⌦ clears a bindable-to-nothing entry (launch items) instead of
        // recording them — a recorder can never swallow the delete keys.
        if allowsClearing, event.keyCode == 51 || event.keyCode == 117 {
            hotkey = nil
            refreshDisplay()
            onHotkeyCleared?()
            return
        }
        // Persist ONLY the four real modifiers. CapsLock / Fn / numericPad are
        // part of `deviceIndependentFlagsMask`, so recording ⌥D with CapsLock on
        // stored a different Hotkey than ⌥D — Carbon still registered ⌥D, but
        // conflict detection compared unequal flags and let a duplicate through.
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let candidate = Hotkey(keyCode: UInt32(event.keyCode),
                               modifierFlags: flags.rawValue)
        guard candidate.isValid else {
            hint.stringValue = "需包含 ⌘/⌥/⌃ 至少一个修饰键"
            return
        }
        hint.stringValue = allowsClearing ? "\(Self.defaultHint)，⌫ 清除" : Self.defaultHint
        // Show the candidate optimistically; the controller validates synchronously
        // inside onHotkeyChanged and calls reject() on failure, restoring the display.
        hotkey = candidate
        refreshDisplay()
        onHotkeyChanged?(candidate)
    }

    /// Rebinds the visible value from the model (selection changes in a list).
    func setHotkey(_ hotkey: Hotkey?) {
        self.hotkey = hotkey
        self.acceptedHotkey = hotkey
        refreshDisplay()
    }

    /// Marks the latest candidate as accepted (called implicitly when the controller
    /// persists the binding) — kept explicit so accept/reject stay symmetric.
    func accept() {
        acceptedHotkey = hotkey
    }

    /// Rejects the pending candidate: shows the reason and reverts the display
    /// to the last accepted (still-persisted) binding.
    func reject(_ message: String) {
        hint.stringValue = message
        hotkey = acceptedHotkey
        refreshDisplay()
    }

    private func refreshDisplay() {
        if let hotkey {
            valueField.stringValue = hotkey.displayText
            valueField.textColor = .controlAccentColor
        } else {
            valueField.stringValue = "未设置"
            valueField.textColor = .tertiaryLabelColor
        }
    }
}
