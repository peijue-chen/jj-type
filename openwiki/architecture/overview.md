---
type: Architecture
title: jj-type Architecture Overview
description: How JJType is structured — MainActor-first concurrency, the AppDelegate integration spine, window level ordering, and the persistence model across UserDefaults and Keychain.
tags: [jjtype, architecture, appkit, concurrency]
timestamp: "2026-11-05T10:22:00+08:00"
---

# Architecture Overview

JJType is a single-windowless (LSUIElement) AppKit app: a status item in the menu bar, global hotkeys, and a set of transient floating panels. The design favors **one shared integration point** — `jj-type/App/AppDelegate.swift` — that wires every subsystem together, with feature folders under `jj-type/` owning their own windows/services.

## Lifecycle & entry point

`jj-type/App/main.swift` is the decisive explicit entry point: it builds `NSApplication.shared`, assigns the `AppDelegate`, and runs. The `@main` AppKit bootstrap was proven broken on the macOS 26 beta / Xcode 26.1 toolchain (delegate never instantiated) and must not be restored.

`AppDelegate.applicationDidFinishLaunching` orders startup deliberately:

1. Create the reused `ResultPanelController` + hook quick-action/QR callbacks.
2. Install status item + rebuild the status menu.
3. **Register global hotkeys immediately** (`reregisterHotkeys`) — before slow first-launch steps (permission prompts, guides, app index, Finder probe), or every shortcut feels dead on fresh installs. Dispatch callbacks attach a few lines later; a hotkey pressed in that millisecond window is a no-op.
4. Subscribe to `SettingsStore` change callbacks (providers → menu rebuild; hotkeys/launch items → hotkey re-registration).
5. Start `ClipboardHistoryService.shared.start()`, the selection bar, keep-awake UI, and other long-running services.

## Concurrency model

Build flags default **everything to MainActor** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`). Real-world implications:

- Carbon hotkey callbacks and `NSEvent` monitors are C/global APIs — they must be `nonisolated` and hop onto the main actor via `MainActor.assumeIsolated`.
- Heavy work is pushed off the main actor: `ScreenCaptureService`, `AppIndex`, `TextRecognizer` (OCR), `QRService.recognizeQR`, mosaic pixelation, and annotation flattening (`AnnotationRenderer.compose`) are `nonisolated` or run in detached tasks.
- Polls must be bounded (interval + deadline) and `NSPasteboard` reads stay on the main queue (main-thread-affine API) via async ticks — never block the main thread.
- Long-running async work uses a single **latest-wins** task: every pipeline entry cancels the previous `inFlightTask` and guards `Task.isCancelled` after each `await`.

## AppDelegate — the integration spine

`AppDelegate` owns (or lazily creates) every major controller: `HotkeyManager`, `TextCaptureService`, `AIClient`, `CaptureOverlayController`, `KeepAwakeService`, and the lazily-created window controllers (`ResultPanelController`, `TranslationWindowController`, `LauncherWindowController`, `SettingsWindowController`, `ClipboardHistoryPanelController`, `QRWindowController`, `DevToolWindowController`).

Key coordination points:

- Hotkey dispatch closures route to `runTranslationWindowFlow()` (⌥D), `runPipeline(mode:)` (⌥E), `runCaptureFlow()` (⌘⇧2), launcher/clipboard/color-picker/QR/dev-tool toggles — see [AI pipeline](/openwiki/architecture/ai-pipeline.md).
- `lastCapturedSourceText` is the single source of truth for quick actions: set by `runPipeline` and the selection bar callback, consumed by `runQuickAction` and `generateQRFromSelection`.
- The result panel, translation window, selection bar, and QR flows are cross-wired through callbacks rather than direct ownership, so any chip can trigger an AI quick action or QR pin.

## Window level ordering (a global invariant)

Floating panels are ranked with explicit `CGWindowLevelForKey(.screenSaverWindow)` offsets. The levels are a **system-wide contract** — changing one breaks the others:

| Component | Level | Why |
|---|---|---|
| Capture overlay | `screenSaverWindow` | Covers full-screen apps, menu bar, Dock; the dim mask carries focus |
| Pins (QR / screencap) | `+1` | Must stay visible above a new capture and be photographed into the frozen frame |
| Capture toolbar | `+2` | At the same level as the overlay, a canvas click raises the overlay and hides the toolbar |
| Toolbar hover hints | `+3` | Never obscured by toolbar chrome |
| Capture toast | `+4` | Transient feedback must never be hidden; ignores mouse events |

Special case: a pin's right-click pop-up menu lives at level 101, below `screenSaverWindow + 1`, so the pin temporarily drops to `.floating` while the menu is up and is raised again on `menuDidClose`. All capture panels use `collectionBehavior` `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`. Full details in [Screen capture](/openwiki/capability/screen-capture.md).

## Persistence model

Settings are split by sensitivity:

- **UserDefaults (`jjtype.*` keys)** — `SettingsStore` (`jj-type/Core/SettingsStore.swift`) persists providers, active provider id, per-action hotkeys, launch items, AI quick actions, capture save directory/format, color-picker history (capped 12), selection-bar toggle, preferred terminal, and guidance flags. Window frames are persisted under explicit keys (`jjtype.translationWindowFrame`, `jjtype.qrWindowFrame`).
- **Keychain** — `KeychainStore` (`jj-type/Core/KeychainStore.swift`) stores API keys only, service `com.aigens.jj-type.provider`, account = provider UUID. Keys never touch UserDefaults. Deleting a provider asks first because the Keychain key is unrecoverable.
- **Files** — clipboard history persists to `~/Library/Application Support/JJType/ClipboardHistory/` (`index.json` + `<uuid>.png`); screenshots save to `~/Pictures/JJType/`; the Finder-terminal diagnostic log goes to `~/Library/Logs/JJType/finder-terminal.log` (256 KB rotation).

Change propagation is callback-driven: `SettingsStore.onProvidersChanged` rebuilds the menu, `onHotkeyChanged`/`onLaunchItemsChanged` re-register hotkeys, and `KeepAwakeService.onChanged` refreshes the status icon/menu section.

## Source map (top level)

```
jj-type/
  App/            main.swift, AppDelegate.swift (integration spine)
  Core/           AIClient, PromptBuilder, LanguageRouter, HotkeyManager,
                  SettingsStore, KeychainStore, TextCaptureService
  Translate/      ResultPanelController, TranslationWindowController
  Launcher/       LauncherWindowController, LaunchItem, SystemCommand,
                  FinderTerminal, AppIndex
  ClipboardHistory/  ClipboardHistoryService, ClipboardHistoryPanelController
  ScreenCapture/  14 files — capture session, annotations, OCR, exporter
  SelectionAction/  QuickAction, SelectionActionBarController
  Tools/          KeepAwakeService, EyedropperController, QRService,
                  QRWindowController, DevToolWindowController
  Settings/       SettingsWindowController, Theme, HotkeyRecorderView
  Permissions/    AccessibilityPermission, AutomationPermission
```

## Open questions / watch items

- No automated tests exist; runtime verification requires a real GUI session with Accessibility granted (`AGENTS.md`).
- Distribution/notarization is pending a channel decision; `build-release.sh` currently signs with the personal `Apple Development` team (36RXHYW79N).