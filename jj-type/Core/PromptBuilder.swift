//
//  PromptBuilder.swift
//  jj-type
//
//  Prompt construction for the single LLM call returning
//  {"corrected": "...", "translation": "..."} plus hardened extraction:
//  reasoning models rehearse JSON inside their thinking (and get truncated),
//  so we scan ALL balanced {...} candidates and keep the LAST valid one.
//  Raw-text fallback only for short brace-free answers from the content field.
//
//  Prompt-language decision (Iter4): instructions are ENGLISH for broader
//  instruction-following and strict-JSON compliance across OpenAI-compatible
//  models; the app UI stays Chinese and translation targets are explicit.
//

import Foundation

struct GrammarResult: Equatable {
    var corrected: String
    var translation: String
}

enum PromptBuilder {
    private struct ReplyDTO: Codable {
        let corrected: String?
        let translation: String?
    }

    /// English system prompt enforcing a pure-JSON reply. Branches on the
    /// four-way detection result so the instruction never contradicts the input.
    static func systemPrompt(mode: TranslateMode, language: DetectedLanguage) -> String {
        let jsonRule = """
        You are a desktop translation and English grammar correction assistant. \
        Reply with ONE single JSON object and nothing else — no explanations, no markdown fences, no thinking. \
        JSON shape: {"corrected": "<corrected English text>", "translation": "<translated text>"}
        """
        switch mode {
        case .translate:
            return jsonRule + """

            Task: translate the user text. "corrected" must be an empty string "".
            "translation" is the translation: English source → Chinese;
            Chinese or mixed source → English; any other language → Chinese.
            """
        case .correctAndTranslate:
            switch language {
            case .english:
                return jsonRule + """

                Task: the input is English. First fix grammar and spelling mistakes
                (keep the meaning and the original language, do not expand) → "corrected".
                Then translate the corrected English into Chinese → "translation".
                If the original text has no mistakes, "corrected" equals the original.
                """
            case .chinese, .mixed:
                return jsonRule + """

                Task: the input is Chinese (or mixed Chinese and English). Skip grammar
                correction: "corrected" must be an empty string "".
                Translate the text into natural English → "translation".
                """
            case .other:
                return jsonRule + """

                Task: the input is neither English nor Chinese. Skip grammar correction:
                "corrected" must be an empty string "".
                Translate the text into Chinese → "translation".
                """
            }
        }
    }

    static func userPrompt(text: String, mode: TranslateMode) -> String {
        switch mode {
        case .translate:
            return "Translate the following text:\n\(text)"
        case .correctAndTranslate:
            return "Process the following text (correct grammar, then translate):\n\(text)"
        }
    }

    // MARK: - Extraction (It12 hardening)

    /// Parses model output. Returns nil when no valid result can be recovered —
    /// callers must then show a clean error instead of rendering raw text.
    static func parse(_ text: String) -> GrammarResult? {
        let cleaned = stripThinkingTags(stripFences(text))
        if let dto = lastValidDTO(in: cleaned) {
            return GrammarResult(corrected: dto.corrected ?? "", translation: dto.translation ?? "")
        }
        // Short brace-free plain answer (only reachable from the content field —
        // reasoning-sourced text is pre-validated in AIClient) → treat as translation.
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 200, !trimmed.contains("{") {
            return GrammarResult(corrected: "", translation: trimmed)
        }
        return nil
    }

    /// Returns the LAST valid JSON-object substring of `text`, if any.
    /// (Reasoning models rehearse the JSON multiple times — the last is final.)
    static func extractLastValidJSON(in text: String) -> String? {
        let cleaned = stripThinkingTags(stripFences(text))
        var lastValid: String?
        for candidate in jsonObjectSubstrings(in: cleaned) {
            if decodeValidDTO(candidate) != nil {
                lastValid = candidate
            }
        }
        return lastValid
    }

    // MARK: - Private helpers

    private static func lastValidDTO(in text: String) -> ReplyDTO? {
        for candidate in jsonObjectSubstrings(in: text).reversed() {
            if let dto = decodeValidDTO(candidate) {
                return dto
            }
        }
        return nil
    }

    /// Valid = decodes AND has at least one non-empty field.
    private static func decodeValidDTO(_ candidate: String) -> ReplyDTO? {
        guard let data = candidate.data(using: .utf8),
              let dto = try? JSONDecoder().decode(ReplyDTO.self, from: data) else { return nil }
        let corrected = (dto.corrected ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = (dto.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty || !translation.isEmpty else { return nil }
        return ReplyDTO(corrected: corrected, translation: translation)
    }

    /// All balanced top-level {...} substrings (string-aware, escape-aware).
    private static func jsonObjectSubstrings(in text: String) -> [String] {
        var results: [String] = []
        let chars = Array(text)
        var depth = 0
        var start: Int?
        var inString = false
        var escaped = false
        for (index, char) in chars.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            switch char {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start {
                        results.append(String(chars[s...index]))
                    }
                }
            default:
                break
            }
        }
        return results
    }

    /// Quick-action reply hardening: weak models wrap the plain answer in JSON
    /// ("{"response": "…"}", "{"rewritten_text": "…"}", or even
    /// "{"<the answer>": ""}") — sometimes with prose around it, sometimes
    /// padded with metadata keys. Extraction rules (deliberately conservative,
    /// so polishing a JSON code snippet is NOT mangled): only string-valued
    /// objects are unwrapped — a single entry yields its value (or the key for
    /// the "answer in the key" shape); multiple entries yield a value ONLY via
    /// a known answer key (no shape guessing). Embedded objects are scanned
    /// LAST-wins, same rationale as the grammar parser. Everything else
    /// returns the cleaned text unchanged.
    static func extractPlainText(_ text: String) -> String {
        let cleaned = stripThinkingTags(stripFences(text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = plainValue(fromJSONObject: cleaned) { return value }
        for candidate in jsonObjectSubstrings(in: cleaned).reversed() {
            if let value = plainValue(fromJSONObject: candidate) { return value }
        }
        return cleaned
    }

    /// Answer-key candidates, in preference order — weak models padding a
    /// plain-text answer with metadata ({"translation": "…", "lang": "en"})
    /// must still yield the ANSWER, not the raw JSON.
    private static let plainAnswerKeys = ["translation", "corrected", "text", "result",
                                          "output", "response", "answer", "content",
                                          "rewritten_text", "polished_text", "corrected_text"]

    /// Unwraps a string-valued JSON object into the plain answer; nil = not
    /// that shape. Single-entry objects: the value (or, for the "answer in the
    /// key" shape, the key). Multi-entry objects: ONLY a known answer key —
    /// no longest-value guessing, so an action whose legitimate OUTPUT is JSON
    /// (polishing / rewriting a JSON snippet) is never mangled.
    private static func plainValue(fromJSONObject candidate: String) -> String? {
        guard let data = candidate.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            return nil
        }
        if object.count == 1 {
            if let value = object.values.first, !value.isEmpty { return value }
            if let key = object.keys.first, !key.isEmpty { return key }
            return nil
        }
        for key in plainAnswerKeys {
            if let value = object[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// Strips ``` fences — also used by the quick-action result path.
    static func stripFences(_ text: String) -> String {
        text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes <think>…</think> blocks; an unclosed <think> truncates the tail.
    static func stripThinkingTags(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
                break
            }
        }
        return result
    }
}
