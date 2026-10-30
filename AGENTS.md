# AGENTS.md — jj-type

Native macOS (AppKit) menu-bar app: AI-powered select-text translation + English
grammar correction via user-configured OpenAI-compatible endpoints.

## Project Facts

- **Platform:** macOS 13.0+ / Swift 5 language mode / AppKit (no SwiftUI, no storyboards — all UI programmatic)
- **App type:** LSUIElement menu-bar app (no Dock icon), Bundle ID `com.aigens.jj-type`, display name **JJType** (`CFBundleName`/`CFBundleDisplayName`; target/product stay `jj-type`)
- **Dependencies:** ZERO third-party. System frameworks only: AppKit, Carbon (global hotkeys), CoreGraphics (CGEvent synthetic ⌘C/⌘V), Security (Keychain), URLSession, NaturalLanguage, ApplicationServices
- **Xcode project:** uses `PBXFileSystemSynchronizedRootGroup` — files dropped into `jj-type/` are compiled automatically; **do NOT hand-register new sources in project.pbxproj**
- **Concurrency:** build sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Everything defaults to MainActor; C callbacks (Carbon) must be `nonisolated` and hop via `MainActor.assumeIsolated`

## Module Map

| File | Responsibility |
|------|----------------|
| `jj-type/AppDelegate.swift` | Status item menu, hotkey wiring, capture → AI → panel pipeline |
| `jj-type/HotkeyManager.swift` | Carbon RegisterEventHotKey; `Hotkey` Codable (UserDefaults); conflict reporting |
| `jj-type/TextCaptureService.swift` | Pasteboard changeCount snapshot → synthetic ⌘C → bounded poll → selected text |
| `jj-type/LanguageRouter.swift` | 4-way detection (english/chinese/mixed/other; CJK+Latin scan + NLLanguageRecognizer) + `TranslateMode` |
| `jj-type/AIClient.swift` | OpenAI-compatible `{baseURL}/chat/completions`, 30 s, non-streaming, Codable models |
| `jj-type/PromptBuilder.swift` | English JSON-contract prompts (4-way language branch) + robust `{"corrected","translation"}` extraction |
| `jj-type/KeychainStore.swift` | API keys (service `com.aigens.jj-type.provider`, account = provider UUID) |
| `jj-type/SettingsStore.swift` | Providers/active/hotkeys in UserDefaults (`jjtype.*` keys) |
| `jj-type/ResultPanelController.swift` | Reused non-activating floating panel: loading/error/result, replace/copy |
| `jj-type/TranslationWindowController.swift` | ⌥+D input-window mode (Bob/Easydict-style): prefill-or-type, Enter/Esc equivalents, auto-copy |
| `jj-type/main.swift` | Explicit entry point — the `@main` AppKit bootstrap is broken on this macOS 26 beta toolchain; do not switch back |
| `jj-type/SettingsWindowController.swift` | Provider CRUD + hotkey customization UI |
| `jj-type/HotkeyRecorderView.swift` | Keyboard capture field for hotkey rebinding |
| `jj-type/AccessibilityPermission.swift` | AXIsProcessTrusted + first-run guidance window |

## Build Commands

```bash
# Debug (shared scheme lives in jj-type.xcodeproj/xcshareddata/)
xcodebuild -project jj-type.xcodeproj -scheme jj-type -configuration Debug build

# Release + timestamped app copy → apps/JJType-<timestamp>.app (uses ./build derived data)
# build-release.sh produces a UNIVERSAL binary (x86_64 + arm64) via script-only ARCHS
# overrides — pbxproj stays host-arch so Xcode dev builds remain fast.
./build-release.sh
```

Signing: `CODE_SIGN_STYLE = Automatic` + `CODE_SIGN_IDENTITY = "Apple Development"`
+ personal `DEVELOPMENT_TEAM = 36RXHYW79N` (requires that team's certificate on
the machine). Publish/notarization is pending a channel decision — do not
switch back to ad-hoc `-` without user approval. Runtime verification (hotkeys,
synthetic ⌘C/⌘V, panel placement) requires a real GUI session with the
Accessibility permission granted to the built app.

## App Icon

- Ships as `jj-type/AppIcon.icns` referenced via `CFBundleIconFile` in Info.plist
  (source PNG + generated sizes under `build-support/`).
- The asset-catalog route (AppIcon.appiconset single-size) is NOT used: this
  Xcode 26.1 actool rejects every documented single-size Contents.json variant
  with "unassigned child". If migrating back, verify in Xcode GUI first.
- Menu bar icon: SF Symbol (`translate`), `isTemplate = true` (adapts to
  light/dark menu bar).

## Conventions

- **Comments in English; UI text in Chinese** (user-facing strings, error messages).
- **Secrets never in code or UserDefaults** — API keys live in Keychain only.
  `mode.json` at the repo root is a local reference file; never commit it, never
  copy its key anywhere.
- **Performance rules:** reuse the result panel (never re-create windows); polling
  must be bounded (interval + deadline) and NSPasteboard reads stay on the main
  queue (main-thread-affine API) via async ticks — never block the main thread;
  cancel superseded Tasks (latest-wins); single shared static URLSession
  (`AIClient.session`); write UserDefaults only on change.
- **Implicitly-unwrapped optionals (`!`)** are forbidden in production paths.
  Exception: the NSWindowController convenience-init bootstrap pattern
  (`SettingsWindowController.store`) — assigned before first use, documented.
- **Privacy note (known trade-off):** while the result panel is visible, a global
  keyDown monitor runs to support Esc dismissal without focus. It is removed on
  dismiss and never logs or forwards events. Do not extend its scope.
- **NEVER `git commit` / `git push`** — the user commits manually.
- Commit message convention (when the user asks to commit):
  `<type>(<scope>): <subject>` — English, imperative, ≤72 chars.
