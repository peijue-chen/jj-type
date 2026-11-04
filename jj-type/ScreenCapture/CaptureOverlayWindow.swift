//
//  CaptureOverlayWindow.swift
//  jj-type
//
//  Borderless, non-activating panel covering exactly one display. It sits above
//  the menu bar / Dock, joins every Space (so full-screen apps are covered) and
//  can become key to receive Esc / Return / arrow keys.
//

import AppKit
import CoreGraphics

final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screenFrame: CGRect) {
        super.init(contentRect: screenFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        setFrame(screenFrame, display: false)
    }

    /// Menu key equivalents (⌘C / ⌘S / ⌘Z) are offered to the overlay view first —
    /// EXCEPT while the inline text editor is up: the field editor is the first
    /// responder then and must keep ⌘C (copy the typed text) and ⌘Z (undo the
    /// typing). Without this guard a ⌘C over selected text would copy the whole
    /// screenshot, close the session and silently drop the annotation.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if firstResponder is NSTextView {
            return super.performKeyEquivalent(with: event)
        }
        if let view = contentView as? CaptureOverlayView, view.handleKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
