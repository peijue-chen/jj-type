//
//  SpeechService.swift
//  jj-type
//
//  Text-to-speech for the translate surfaces (translation window, result
//  panel, selection bar). One shared AVSpeechSynthesizer: a second click on
//  the same text stops it, a click on different text replaces it. The voice
//  follows the detected language so an English word is never read with a
//  Chinese voice (and vice versa).
//
//  No permission, no network, no pasteboard access — speaking must stay a
//  pure side effect of an explicit click.
//

import AVFoundation
import AppKit

extension Notification.Name {
    /// Posted whenever the speaking state changes (start / finish / stop) so
    /// every speaker button can flip between "speaker" and "stop" glyphs.
    static let jjTypeSpeechStateChanged = Notification.Name("jjTypeSpeechStateChanged")
}

final class SpeechService: NSObject {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()
    /// Text of the utterance currently being spoken (nil when idle). Used to
    /// tell "click again = stop" apart from "click another text = replace".
    private(set) var currentText: String?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// True when `text` is the utterance in flight (queued OR speaking).
    /// Deliberately keyed on `currentText`, not `synthesizer.isSpeaking`:
    /// the latter stays false for a beat after `speak()` returns, and a click
    /// in that window must be a stop, not a restart.
    func isSpeaking(_ text: String) -> Bool {
        guard let currentText else { return false }
        return currentText == Self.normalize(text)
    }

    /// Speaker-button behavior: same text → stop, anything else → speak it.
    func toggle(_ text: String) {
        let trimmed = Self.normalize(text)
        guard !trimmed.isEmpty else { return }
        if isSpeaking(trimmed) {
            stop()
        } else {
            speak(trimmed)
        }
    }

    func speak(_ text: String) {
        let trimmed = Self.normalize(text)
        guard !trimmed.isEmpty else { return }
        // Replacing an utterance: stop first so the two never overlap. The
        // resulting didCancel is ignored by the identity check in finish().
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // State flips IMMEDIATELY (glyphs + a rapid second click = stop).
        currentText = trimmed
        notifyStateChanged()
        // Known AVSpeechSynthesizer quirk on macOS: a speak() issued in the
        // same beat as stopSpeaking(at: .immediate) can be silently dropped —
        // always give the synthesizer a beat. The identity check in
        // startUtterance lets a stop or a newer text win inside the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.startUtterance(trimmed)
        }
    }

    private func startUtterance(_ trimmed: String) {
        // Superseded (another text) or stopped within the deferral window.
        guard currentText == trimmed else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.voice(for: trimmed)
        // A single word is read slightly slower — it is usually a word the
        // user is trying to learn the pronunciation of.
        utterance.rate = trimmed.contains(where: \.isWhitespace)
            ? AVSpeechUtteranceDefaultSpeechRate
            : 0.45
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking || currentText != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentText = nil
        notifyStateChanged()
    }

    // MARK: - Private

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Voice matching the detected language; nil lets the system pick its
    /// default voice (used for languages we have no explicit mapping for).
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        switch LanguageRouter.detect(text) {
        case .english:
            return AVSpeechSynthesisVoice(language: "en-US")
        case .chinese, .mixed:
            // Mixed text is mostly Chinese with embedded English terms — the
            // Chinese voice reads both correctly.
            return AVSpeechSynthesisVoice(language: "zh-CN")
        case .other:
            return nil
        }
    }

    private func notifyStateChanged() {
        NotificationCenter.default.post(name: .jjTypeSpeechStateChanged, object: self)
    }

    /// Landing point for the delegate callbacks. A late callback from a
    /// REPLACED utterance must not clear the state of the new one, hence the
    /// text identity check.
    private func finish(_ spokenText: String) {
        guard currentText == spokenText else { return }
        currentText = nil
        notifyStateChanged()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate {
    /// Delegate callbacks are not guaranteed to arrive on the main thread —
    /// hop explicitly instead of assuming isolation.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let spoken = utterance.speechString
        Task { @MainActor in self.finish(spoken) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let spoken = utterance.speechString
        Task { @MainActor in self.finish(spoken) }
    }
}
