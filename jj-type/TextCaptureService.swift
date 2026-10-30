//
//  TextCaptureService.swift
//  jj-type
//
//  Captures the current text selection — Accessibility-first (It10 #5):
//  the system-wide focused element's kAXSelectedTextAttribute is read directly
//  (no clipboard touch, no synthetic ⌘C). The AX query runs on a background
//  queue with a 1.2 s messaging timeout (It11 #1: a synchronous main-thread
//  query with the default 6 s global timeout stalled the whole UI when the
//  target app was busy — the "hotkey fails to open the window" bug). Only when
//  AX itself is unavailable does the legacy snapshot → ⌘C → changeCount-poll
//  fallback run (main queue, bounded ticks).
//

import AppKit
import ApplicationServices
import CoreGraphics

enum CaptureError: LocalizedError, Equatable {
    case accessibilityNotGranted
    case emptySelection
    case timeout

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "未获得辅助功能权限，无法抓取选中文本"
        case .emptySelection:
            return "未检测到选中文本，请先选中要处理的内容"
        case .timeout:
            return "抓取选中文本超时，请重试"
        }
    }
}

final class TextCaptureService {
    private let pollInterval: TimeInterval = 0.02
    private let axQueue = DispatchQueue(label: "com.aigens.jj-type.axcapture", qos: .userInitiated)
    /// Bounds every AX IPC round-trip so a busy target app cannot stall us.
    private let axTimeout: TimeInterval = 1.2

    private enum AXSelection {
        case text(String)
        case noSelection
        case unavailable
    }

    /// Entry point for both hotkey flows. Returns on the main actor.
    func captureSelectedText(timeout: TimeInterval = 1.0,
                             completion: @escaping @MainActor (Result<String, CaptureError>) -> Void) {
        // Defensive entry check (AppDelegate gates upstream; keep the error case reachable).
        guard AccessibilityPermission.isGranted else {
            completion(.failure(.accessibilityNotGranted))
            return
        }

        // AX IPC goes to a background queue — the main thread (and any UI we
        // already ordered front) stays responsive while it resolves.
        axQueue.async { [axTimeout] in
            let selection = Self.axSelection(timeout: Float(axTimeout))
            DispatchQueue.main.async {
                switch selection {
                case .text(let raw):
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(text.isEmpty ? .failure(.emptySelection) : .success(text))
                case .noSelection:
                    // AX works and reports nothing selected → manual-input mode.
                    // Never simulate ⌘C here — that is what copied caret text.
                    completion(.failure(.emptySelection))
                case .unavailable:
                    self.legacyClipboardCapture(timeout: timeout, completion: completion)
                }
            }
        }
    }

    // MARK: - Accessibility-first capture

    /// Pure C-API call, no state — safe to run nonisolated on the AX queue.
    private nonisolated static func axSelection(timeout: Float) -> AXSelection {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedValue = focusedRef else {
            return .unavailable
        }
        let focused = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, timeout)
        var selectedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString,
                                                   &selectedRef)
        switch status {
        case .success:
            if let selected = selectedRef as? String {
                return .text(selected)
            }
            return .noSelection
        case .attributeUnsupported, .apiDisabled, .cannotComplete:
            // App does not expose AX selected text (terminals, some Electron
            // views) — fall back to the clipboard flow.
            return .unavailable
        default:
            // e.g. kAXErrorNoValue: the attribute exists but nothing is selected.
            return .noSelection
        }
    }

    // MARK: - Legacy clipboard fallback

    private func legacyClipboardCapture(timeout: TimeInterval,
                                        completion: @escaping @MainActor (Result<String, CaptureError>) -> Void) {
        let pasteboard = NSPasteboard.general
        let previousCount = pasteboard.changeCount

        postCommandC()

        let deadline = Date().addingTimeInterval(timeout)
        pollPasteboard(pasteboard, previousCount: previousCount,
                       deadline: deadline, completion: completion)
    }

    private func pollPasteboard(_ pasteboard: NSPasteboard,
                                previousCount: Int,
                                deadline: Date,
                                completion: @escaping @MainActor (Result<String, CaptureError>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            if pasteboard.changeCount != previousCount {
                let text = (pasteboard.string(forType: .string) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    completion(.failure(.emptySelection))
                } else {
                    completion(.success(text))
                }
            } else if Date() < deadline {
                self.pollPasteboard(pasteboard, previousCount: previousCount,
                                    deadline: deadline, completion: completion)
            } else {
                completion(.failure(.timeout))
            }
        }
    }

    /// Synthesizes ⌘C key-down/key-up to the session event tap (needs Accessibility).
    private func postCommandC() {
        let keyCodeC: CGKeyCode = 8
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false)
        keyDown?.flags = CGEventFlags.maskCommand
        keyUp?.flags = CGEventFlags.maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
