//
//  LanguageRouter.swift
//  jj-type
//
//  Local fast language pre-check (NLLanguageRecognizer + CJK/Latin scan) that
//  decides the correction/translation branch for each mode.
//

import Foundation
import NaturalLanguage

enum TranslateMode: String {
    case translate             // ⌥+D — pure translation
    case correctAndTranslate   // ⌥+E — grammar correction + translation
}

enum DetectedLanguage: Equatable {
    case english
    case chinese
    case mixed   // contains BOTH CJK ideographs and latin letters
    case other
}

/// Routing outcome derived from the detected language. The language flows into
/// PromptBuilder so prompts never assert a wrong input language.
struct TranslationTask: Equatable {
    let language: DetectedLanguage
}

enum LanguageRouter {
    static func detect(_ text: String) -> DetectedLanguage {
        if containsCJK(text) && containsLatin(text) {
            return .mixed
        }
        if containsCJK(text) {
            return .chinese
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .english:
            return .english
        case .simplifiedChinese, .traditionalChinese:
            return .chinese
        default:
            return .other
        }
    }

    static func makeTask(text: String) -> TranslationTask {
        // Direction rule: English → Chinese; Chinese/Mixed → English; other → Chinese.
        // Correction only applies to English and is decided in the prompt.
        TranslationTask(language: detect(text))
    }

    // MARK: - Private

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // CJK Unified Ideographs (+ Extension A) and Compatibility Ideographs.
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    private static func containsLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            // Basic latin letters (A-Z, a-z).
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }
    }
}
