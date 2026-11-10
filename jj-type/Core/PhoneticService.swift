//
//  PhoneticService.swift
//  jj-type
//
//  Offline IPA lookup for a single English word, backed by the system
//  dictionaries (Dictionary Services / DCSCopyTextDefinition). No network, no
//  permission, no AI request — a word's pronunciation must appear instantly.
//
//  The raw entry is plain text shaped like:
//      hello | BrE həˈləʊ, hɛˈləʊ, AmE həˈloʊ, hɛˈloʊ | A. noun 问候 …
//  so the first |…| group is the pronunciation. Two guards matter:
//    * the entry must START with the queried word — the user's dictionary
//      order can resolve an English spelling to a Chinese headword
//      (run → 瞤 rún), which has no usable IPA;
//    * the group must contain non-ASCII scalars — a plain word in pipes is
//      not a pronunciation.
//

import Foundation
import CoreServices

enum PhoneticService {
    /// Serial queue: the first lookup loads dictionaries (tens of ms) and must
    /// never block the main thread. All cache access happens here too.
    /// `nonisolated(unsafe)` is required here: the project builds with
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so a plain static would be
    /// main-actor isolated and unreachable from the nonisolated lookup.
    private nonisolated(unsafe) static let queue =
        DispatchQueue(label: "com.aigens.jj-type.phonetic", qos: .userInitiated)
    /// word (lowercased) → display string; "" records a miss so a word the
    /// dictionaries do not know is not looked up again on every keystroke.
    private nonisolated(unsafe) static var cache: [String: String] = [:]
    private static let cacheLimit = 256

    // MARK: - Public API

    /// True for a single English word (letters plus inner ' ’ -), which is the
    /// only input a dictionary pronunciation makes sense for.
    nonisolated static func isSingleEnglishWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return false }
        guard let first = trimmed.unicodeScalars.first, isASCIILetter(first) else { return false }
        for scalar in trimmed.unicodeScalars {
            if isASCIILetter(scalar) { continue }
            switch scalar.value {
            case 0x27, 0x2019, 0x2D: // ' ’ -
                continue
            default:
                return false
            }
        }
        return true
    }

    /// Looks up the pronunciation of a single English word. `completion` is
    /// always called on the main thread; nil means "no phonetic available"
    /// (not a single word, unknown word, or no dictionary installed).
    nonisolated static func lookup(_ text: String,
                                   completion: @escaping (String?) -> Void) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSingleEnglishWord(word) else {
            completion(nil)
            return
        }
        let key = word.lowercased()
        queue.async {
            if let cached = cache[key] {
                let value = cached.isEmpty ? nil : cached
                DispatchQueue.main.async { completion(value) }
                return
            }
            let result = definitionPhonetic(for: word)
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = result ?? ""
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Dictionary lookup

    private nonisolated static func definitionPhonetic(for word: String) -> String? {
        let query = word as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(query))
        guard let entry = DCSCopyTextDefinition(nil, query, range)?.takeRetainedValue() as String?
        else { return nil }
        // Reject a Chinese headword that merely shares the spelling.
        guard entry.lowercased().hasPrefix(word.lowercased()) else { return nil }
        guard let open = entry.firstIndex(of: "|"),
              let close = entry[entry.index(after: open)...].firstIndex(of: "|")
        else { return nil }
        let group = String(entry[entry.index(after: open)..<close])
        guard group.unicodeScalars.contains(where: { $0.isASCII == false }) else { return nil }
        return format(group)
    }

    /// "BrE həˈləʊ, hɛˈləʊ, AmE həˈloʊ, hɛˈloʊ" → "英 [həˈləʊ] · 美 [həˈloʊ]".
    /// The first reading of each accent is enough for a compact label; a group
    /// without accent prefixes is shown as-is. The dictionary's BrE/AmE tags
    /// are replaced by the plain 英/美 labels — the label is read by Chinese
    /// users, not by a phonetician.
    private nonisolated static func format(_ group: String) -> String? {
        let segments = group.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let british = segments.first { $0.hasPrefix("BrE ") }
        let american = segments.first { $0.hasPrefix("AmE ") }
        switch (british, american) {
        case let (british?, american?):
            return "英 [\(reading(british, dropping: "BrE "))] · 美 [\(reading(american, dropping: "AmE "))]"
        case let (british?, nil):
            return "英 [\(reading(british, dropping: "BrE "))]"
        case let (nil, american?):
            return "美 [\(reading(american, dropping: "AmE "))]"
        case (nil, nil):
            let plain = group.trimmingCharacters(in: .whitespaces)
            return plain.isEmpty ? nil : plain
        }
    }

    /// "BrE həˈləʊ" → "həˈləʊ".
    private nonisolated static func reading(_ segment: String, dropping prefix: String) -> String {
        segment.hasPrefix(prefix)
            ? String(segment.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            : segment
    }

    private nonisolated static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }
}
