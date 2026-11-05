---
type: Architecture
title: AI Pipeline — capture, prompt, request, result
description: The end-to-end JJType AI flow — selection capture (AX first, synthetic ⌘C fallback), 4-way language detection, JSON-contract prompts, OpenAI-compatible requests with reasoning-content fallback, and the reused result panel.
tags: [jjtype, ai, pipeline, openai, prompt]
timestamp: "2026-11-05T10:24:00+08:00"
---

# AI Pipeline

The AI pipeline is the core of JJType: grab the user's selected text, translate and/or grammar-correct it through a user-configured OpenAI-compatible endpoint, and surface the result in a floating panel. It is orchestrated end-to-end by `AppDelegate` (`jj-type/App/AppDelegate.swift`), which also owns the "latest-wins" cancellation semantics.

## Capture: text selection

`TextCaptureService` (`jj-type/Core/TextCaptureService.swift`) resolves the current selection with two strategies:

1. **AX-first**: read `kAXSelectedTextAttribute` from the focused element on a background queue with a ~1.2 s IPC timeout. This is the primary path.
2. **Legacy clipboard fallback** (browsers/Electron lack the AX attribute): snapshot the pasteboard `changeCount`, post a synthetic ⌘C (`CGEvent`), then poll every 20 ms for up to 1.0 s for a `changeCount` change. Own write-backs are suppressed via the snapshot.

`AppDelegate.runPipeline(mode:)` shows the result panel in a loading state **near the cursor**, cancels any in-flight request, dismisses the selection bar, and refreshes the quick-action chips from `SettingsStore.aiActions` so settings edits apply live.

## Language detection

`LanguageRouter` (`jj-type/Core/LanguageRouter.swift`) classifies the captured text into 4 buckets — `english`, `chinese`, `mixed`, `other` — by scanning CJK (Unicode scalar ranges) and Latin ranges, falling back to `NLLanguageRecognizer`. It also carries the `TranslateMode` (`.translate` vs `.correctAndTranslate`), which branches prompt construction.

## Prompt contract

`PromptBuilder` (`jj-type/Core/PromptBuilder.swift`) builds **English system prompts enforcing a strict JSON output contract** `{"corrected": "...", "translation": "..."}`, branching on mode × language:

- `.translate`: English → Chinese; Chinese/mixed → English; other → Chinese.
- `.correctAndTranslate` + English: correct grammar into `corrected`, translate to Chinese.
- `.correctAndTranslate` + Chinese/mixed/other: correction skipped (empty `corrected`), translate to English/Chinese.

Parsing (`PromptBuilder.parse`) strips thinking tags and code fences, then scans for the **last valid JSON object** (decoded into a `ReplyDTO` with at least one non-empty field); a short brace-free reply (≤200 chars) falls back to raw translation. `extractPlainText` unwraps single-entry JSON objects for quick-action replies.

## Request & response

`AIClient` (`jj-type/Core/AIClient.swift`) POSTs `{baseURL}/chat/completions`, non-streaming, temperature 0.2, 30 s timeout, through a single shared ephemeral `URLSession`. Notable behaviors:

- **`response_format: json_object` with a 400 fallback** — strict OpenAI-compatible servers may reject JSON mode; `attempt()` retries without it on HTTP 400.
- **Reasoning-model support**: if `content` is empty, it pulls the last valid JSON from `reasoning_content` (GLM/DeepSeek-style models put output there). Raw thinking text is never returned.
- **Truncation retry**: on `finish_reason == "length"` with empty text, retries once at doubled `max_tokens` (8192) before throwing `AIError.noValidResult(truncated: true)`.
- **Connection test**: `testConnection` sends "Reply with exactly: OK", 10 s timeout, no JSON mode — used by the Settings provider form.

Errors surface as localized Chinese messages (`AIError` in `AIClient.swift`).

## Result surfaces

- **`ResultPanelController`** (`jj-type/Translate/ResultPanelController.swift`) — a reused, non-activating 380px floating panel with loading / result / error states. Shows corrected + translation with labels, quick-action chips (visible during loading too, enabling cancel-by-click), a QR chip, **替换原文** (replace: copies then synthetic ⌘V after 0.1 s, Accessibility-gated) and **复制**. Auto-copies the result; Esc/click-outside dismisses.
- **`TranslationWindowController`** (`jj-type/Translate/TranslationWindowController.swift`) — the ⌥D input-window mode presents without activating, captures the selection while the original app still has focus, pre-fills + translates, or focuses an empty input for typing. Input/result persist to `jjtype.lastTranslation.*`; frame persists to `jjtype.translationWindowFrame`.

## Quick actions

`QuickAction` (`jj-type/SelectionAction/QuickAction.swift`) models AI quick actions with a `{text}` template placeholder (absent placeholder → text appended). Three built-ins (翻译 / 润色 / 改写) carry **fixed UUIDs** — the last UUID group must be exactly 12 hex digits; the earlier 13-digit format crashed launch and was fixed in 1.6.0. Built-ins are seeded into the persisted `aiActions` list so prompts are editable but not deletable. `runQuickAction` uses `lastCapturedSourceText` and renders through the same result panel.

## Trigger wiring

The whole pipeline is triggered by the global hotkey manager (`jj-type/Core/HotkeyManager.swift`): Carbon `RegisterEventHotKey` with signature `'jjty'`, built-in ids 1–8 (translate, correct+translate, capture, launcher, clipboard history, color picker, QR, dev tool) and dynamic launch-item slots 100–999. Per-binding conflict detection unregisters everything then re-registers id-by-id; failures disable only the conflicting binding and show a named alert instead of killing the rest. Hotkeys are stored as JSON `Hotkey` structs with `jjtype.hotkey.*` keys, require at least one of ⌘/⌥/⌃, and deliberately avoid ⌥Space (Alfred's default). See [HotkeyManager](/openwiki/architecture/overview.md) notes and the [Settings page](/openwiki/capability/settings-permissions.md) for the recorder.