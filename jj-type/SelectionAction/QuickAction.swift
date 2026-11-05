//
//  QuickAction.swift
//  jj-type
//
//  AI quick actions for the selection result panel: four built-ins
//  (翻译 / 纠正 / 润色 / 改写) plus user-defined prompt templates ({text}
//  placeholder), persisted by SettingsStore.
//

import Foundation

/// One AI quick action. `prompt` is a template: `{text}` is replaced with the
/// captured selection at run time; a template without the placeholder gets the
/// text appended instead (so naive custom prompts still work).
struct QuickAction: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var prompt: String

    /// Fixed ids so the built-ins keep their identity across launches.
    /// The last UUID group must be EXACTLY 12 hex digits — an earlier format
    /// produced 13 and `UUID(uuidString:)` returned nil, crashing launch.
    static func fixedId(_ index: Int) -> UUID {
        let suffix = String(format: "%012d", index)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    func resolvedPrompt(for text: String) -> String {
        prompt.contains("{text}")
            ? prompt.replacingOccurrences(of: "{text}", with: text)
            : prompt + "\n\n" + text
    }
}

enum QuickActionCatalog {
    /// The built-in 翻译 action is NOT run through the template pipeline: it is
    /// routed to the SAME LanguageRouter + PromptBuilder pipeline as the
    /// ⌥D translation window (identical prompt, JSON contract and parser).
    /// Rationale (2026-11-05): the template pipeline forced `json_object` on a
    /// plain-text instruction, and for long selections reasoning models burned
    /// the token budget / returned multi-key or truncated JSON that the
    /// plain-text extractor could not recover — the selection-bar translation
    /// broke exactly where the translation window worked. The persisted prompt
    /// of this entry is therefore informational (kept editable for parity of
    /// the settings UI, but not sent).
    static let translateActionID = QuickAction.fixedId(1)

    /// Built-in actions (翻译 / 纠正 / 润色 / 改写) — user decision 2026-11-03,
    /// 纠正 added 2026-11-05. Order mirrors the ⌥D/⌥E hotkey pair.
    static let builtIns: [QuickAction] = [
        QuickAction(
            id: QuickAction.fixedId(1),
            name: "翻译",
            prompt: """
            Translate the following text: English source → Chinese; Chinese or mixed \
            source → English; any other language → Chinese. Output ONLY the translation, \
            nothing else:
            {text}
            """
        ),
        QuickAction(
            id: QuickAction.fixedId(4),
            name: "纠正",
            prompt: """
            Correct the grammar, spelling and punctuation of the following text while \
            keeping the original language, meaning and wording. Do not expand or rewrite. \
            Output ONLY the corrected text, nothing else:
            {text}
            """
        ),
        QuickAction(
            id: QuickAction.fixedId(2),
            name: "润色",
            prompt: """
            Polish the following text so it reads natural and fluent while keeping the \
            original meaning and language. Fix grammar, word choice and tone. Output \
            ONLY the polished text, nothing else:
            {text}
            """
        ),
        QuickAction(
            id: QuickAction.fixedId(3),
            name: "改写",
            prompt: """
            Rewrite the following text with different wording and sentence structures \
            while conveying the same meaning in the same language. Output ONLY the \
            rewritten text, nothing else:
            {text}
            """
        ),
    ]

    /// The full actions row = built-ins followed by the user's custom actions.
    static func actions(custom: [QuickAction]) -> [QuickAction] {
        builtIns + custom
    }

    /// Fixed ids of the built-ins — used to seed them into the persisted
    /// action list (editable prompts) and to forbid their deletion.
    static var builtInIds: Set<UUID> {
        Set(builtIns.map(\.id))
    }
}
