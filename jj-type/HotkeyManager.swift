//
//  HotkeyManager.swift
//  jj-type
//
//  Global hotkeys via Carbon RegisterEventHotKey.
//

import AppKit
import Carbon.HIToolbox

/// A user-configurable hotkey, persisted as JSON in UserDefaults.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifierFlags: UInt

    static let defaultTranslate = Hotkey(keyCode: UInt32(kVK_ANSI_D), modifierFlags: NSEvent.ModifierFlags.option.rawValue)
    static let defaultCorrect = Hotkey(keyCode: UInt32(kVK_ANSI_E), modifierFlags: NSEvent.ModifierFlags.option.rawValue)
    static let defaultCapture = Hotkey(keyCode: UInt32(kVK_ANSI_2),
                                       modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    /// Launcher: ⌥O ("open"). Deliberately NOT ⌥Space, which is Alfred's own
    /// default — the two apps are expected to live side by side.
    static let defaultLauncher = Hotkey(keyCode: UInt32(kVK_ANSI_O), modifierFlags: NSEvent.ModifierFlags.option.rawValue)
    /// Clipboard history: ⌥V — the panel pastes back what you pick.
    static let defaultClipboardHistory = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifierFlags: NSEvent.ModifierFlags.option.rawValue)
    /// Screen color picker: ⌥P.
    static let defaultColorPicker = Hotkey(keyCode: UInt32(kVK_ANSI_P), modifierFlags: NSEvent.ModifierFlags.option.rawValue)
    /// Dedicated QR window: ⌥Q.
    static let defaultQRCode = Hotkey(keyCode: UInt32(kVK_ANSI_Q), modifierFlags: NSEvent.ModifierFlags.option.rawValue)

    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Human-readable representation, e.g. "⌥D".
    var displayText: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += Self.letter(forKeyCode: keyCode)
        return text
    }

    /// Must include at least one of ⌘/⌥/⌃ so plain typing is never swallowed.
    var isValid: Bool {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        return flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
    }

    /// Keys that carry no character; `UCKeyTranslate` would render them as the
    /// useless "Key 49" fallback.
    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "⏎", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Maps a virtual key code to its unshifted letter/symbol for display.
    static func letter(forKeyCode keyCode: UInt32) -> String {
        if let name = specialKeyNames[Int(keyCode)] { return name }
        // Load the current keyboard layout and translate the key code without modifiers.
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        if let layout = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue() as TISInputSource?,
           let layoutData = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) {
            let layoutDataRef = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
            let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layoutDataRef), to: UnsafePointer<UCKeyboardLayout>.self)
            UCKeyTranslate(keyboardLayout, UInt16(keyCode), UInt16(kUCKeyActionDisplay),
                           0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                           &deadKeyState, 4, &length, &chars)
            if length > 0, let scalar = Unicode.Scalar(chars[0]) {
                return String(Character(scalar)).uppercased()
            }
        }
        return "Key \(keyCode)"
    }
}

final class HotkeyManager {
    enum HotkeyID: UInt32, CaseIterable {
        case translate = 1
        case correctAndTranslate = 2
        case capture = 3
        case launcher = 4
        case clipboardHistory = 5
        case colorPicker = 6
        case qrCode = 7
    }

    /// Dynamic ids (launch items) start here so they can never collide with the
    /// three built-in actions.
    static let launchItemSlotRange: ClosedRange<UInt32> = 100...999

    /// 'jjty' — matches the registered EventHotKeyID signature.
    private static let signature: OSType = 0x6A_6A_74_79

    var onTranslate: (() -> Void)?
    var onCorrectAndTranslate: (() -> Void)?
    var onCapture: (() -> Void)?
    var onLauncher: (() -> Void)?
    var onClipboardHistory: (() -> Void)?
    var onColorPicker: (() -> Void)?
    var onQRCode: (() -> Void)?
    /// Fires with the launch item's own hotkey slot (see `launchItemSlotRange`).
    var onLaunchItem: ((UInt32) -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    init() {
        installCarbonHandler()
        // Registration is intentionally NOT done here: the caller must consume
        // reregister()'s conflict results (see AppDelegate.applicationDidFinishLaunching).
    }

    deinit {
        unregisterAll()
    }

    /// Registers exactly this set of bindings, replacing whatever was registered
    /// before (built-in actions *and* launch items). Ids whose combination is
    /// already taken by another app stay unregistered and come back in the
    /// result, so the caller can name them; the rest are live either way.
    @discardableResult
    func reregister(_ bindings: [UInt32: Hotkey]) -> [UInt32] {
        unregisterAll()
        var failed: [UInt32] = []
        for (id, hotkey) in bindings where !register(id: id, hotkey: hotkey) {
            failed.append(id)
        }
        return failed.sorted()
    }

    // MARK: - Carbon bridge

    private func register(id: UInt32, hotkey: Hotkey) -> Bool {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        refs[id] = newRef
        return true
    }

    private func unregisterAll() {
        for (_, ref) in refs {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
    }

    private func installCarbonHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // The Carbon callback arrives on the main thread for the application target.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var storage = EventHotKeyID()
            HotkeyManager.readHotKeyID(from: event, into: &storage)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.dispatch(id: storage.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        handlerInstalled = true
    }

    fileprivate func dispatch(id: UInt32) {
        // Carbon handler is nonisolated; hop back to the main actor for UI work.
        MainActor.assumeIsolated {
            if let hotkeyID = HotkeyID(rawValue: id) {
                switch hotkeyID {
                case .translate:
                    onTranslate?()
                case .correctAndTranslate:
                    onCorrectAndTranslate?()
                case .capture:
                    onCapture?()
                case .launcher:
                    onLauncher?()
                case .clipboardHistory:
                    onClipboardHistory?()
                case .colorPicker:
                    onColorPicker?()
                case .qrCode:
                    onQRCode?()
                }
            } else {
                onLaunchItem?(id)
            }
        }
    }

    /// Reads the hotkey id out of a Carbon hot-key event (typed pointer so & counts as inout).
    private static func readHotKeyID(from event: EventRef?, into pointer: UnsafeMutablePointer<EventHotKeyID>) {
        GetEventParameter(event, UInt32(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil,
                          UnsafeMutableRawPointer(pointer))
    }
}
