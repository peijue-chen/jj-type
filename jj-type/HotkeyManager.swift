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

    /// Maps a virtual key code to its unshifted letter/symbol for display.
    static func letter(forKeyCode keyCode: UInt32) -> String {
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
    enum HotkeyID: UInt32 {
        case translate = 1
        case correctAndTranslate = 2

        var signature: OSType {
            // 'jjty' — matches the registered EventHotKeyID signature.
            0x6A_6A_74_79
        }
    }

    var onTranslate: (() -> Void)?
    var onCorrectAndTranslate: (() -> Void)?

    private var translateRef: EventHotKeyRef?
    private var correctRef: EventHotKeyRef?
    private var translateHotkey: Hotkey
    private var correctHotkey: Hotkey
    private var handlerInstalled = false

    init(translate: Hotkey, correct: Hotkey) {
        translateHotkey = translate
        correctHotkey = correct
        installCarbonHandler()
        // Registration is intentionally NOT done here: the caller must consume
        // reregister()'s conflict result (see AppDelegate.applicationDidFinishLaunching).
    }

    deinit {
        unregisterAll()
    }

    /// Re-registers both hotkeys. Returns the HotkeyID that failed to register (conflict), nil on success.
    @discardableResult
    func reregister(translate: Hotkey, correct: Hotkey) -> HotkeyID? {
        unregisterAll()
        translateHotkey = translate
        correctHotkey = correct

        if register(&translateRef, id: .translate, hotkey: translate) {
            if register(&correctRef, id: .correctAndTranslate, hotkey: correct) {
                return nil
            }
            unregisterAll()
            return .correctAndTranslate
        }
        return .translate
    }

    // MARK: - Carbon bridge

    private func register(_ ref: inout EventHotKeyRef?, id: HotkeyID, hotkey: Hotkey) -> Bool {
        let hotKeyID = EventHotKeyID(signature: id.signature, id: id.rawValue)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, newRef != nil else { return false }
        ref = newRef
        return true
    }

    private func unregisterAll() {
        if let ref = translateRef { UnregisterEventHotKey(ref); translateRef = nil }
        if let ref = correctRef { UnregisterEventHotKey(ref); correctRef = nil }
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
            guard HotkeyID(rawValue: id) == .translate || HotkeyID(rawValue: id) == .correctAndTranslate else { return }
            if id == HotkeyID.translate.rawValue {
                onTranslate?()
            } else {
                onCorrectAndTranslate?()
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
