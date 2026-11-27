---
type: Guide
title: jj-type Quickstart
description: Entry point for the JJType code wiki — a native macOS menu-bar app for AI text translation, grammar correction, screen capture, and power-user utilities, with zero third-party dependencies.
tags: [jjtype, macos, appkit, quickstart]
timestamp: "2026-12-07"
---

# jj-type Quickstart

JJType is a native macOS (14.0+) menu-bar application written in Swift/AppKit that turns selected text into AI output (translation + English grammar correction through user-configured OpenAI-compatible endpoints) and bundles a full suite of desktop utilities: an Alfred-style launcher, screenshot capture with annotations and OCR, clipboard history, color eyedropper, QR codes, keep-awake, input source keeper, network watchdog (auto failover Wi-Fi + VPN restart + webhook), and a developer tool window. There are zero third-party dependencies — only system frameworks (AppKit, Carbon, CoreGraphics, Security, URLSession, NaturalLanguage, Vision, ApplicationServices).

The repo is a single Xcode project (`jj-type.xcodeproj`) with all Swift sources under `jj-type/` organized by feature folders. The `PBXFileSystemSynchronizedRootGroup` project setting means **any file dropped under `jj-type/` is compiled automatically — never hand-register sources in `project.pbxproj`**.

## How to use this wiki

- **[Architecture overview](/openwiki/architecture/overview.md)** — app lifecycle, the MainActor concurrency model, window levels, persistence, and how the parts connect.
- **[AI pipeline](/openwiki/architecture/ai-pipeline.md)** — capture → language detection → prompt → OpenAI-compatible request → result panel; the reasoning-content fallback and latest-wins cancellation.
- **[Launcher & system commands](/openwiki/capability/launcher.md)** — ⌥O app launcher, app index, Alfred-style system commands, and the Finder-toolbar "open terminal here" flow.
- **[Utilities](/openwiki/capability/tools.md)** — keep-awake, eyedropper, QR windows, developer tool window, and clipboard history.
- **[Screen capture](/openwiki/capability/screen-capture.md)** — the capture session, annotation model, toolbar, OCR, exporting, and the Screen Recording permission flow.
- **[Settings & permissions](/openwiki/capability/settings-permissions.md)** — the System-Settings-style window, the Theme design system, and the Accessibility/Automation/Screen-Recording permission guides.
- **[Network watchdog](/openwiki/capability/network-watchdog.md)** — automatic failover to backup Wi-Fi, VPN restart, app relaunch, and webhook notifications when the network drops.
- **[Build & release](/openwiki/operations/build-release.md)** — build commands, universal release script, versioning/changelog procedure, icon pipeline, and the CI workflow.

## What the app does (feature map)

| Feature | Global shortcut (default, rebindable) | Status-bar entry | Key source files |
|---|---|---|---|
| Translate selection (⌥D-style input window) | ⌥D | — | `jj-type/Translate/TranslationWindowController.swift`, `jj-type/Core/AIClient.swift` |
| Correct + translate selection (floating result panel) | ⌥E | — | `jj-type/App/AppDelegate.swift`, `jj-type/Translate/ResultPanelController.swift` |
| Screen capture with annotations/OCR | ⌘⇧2 | — | `jj-type/ScreenCapture/` |
| Launcher (Alfred-style) | ⌥O | — | `jj-type/Launcher/LauncherWindowController.swift`, `AppIndex.swift` |
| Clipboard history | ⌥V | toggle in menu | `jj-type/ClipboardHistory/` |
| Color eyedropper | ⌥P | — | `jj-type/Tools/EyedropperController.swift` |
| QR generator/recognizer | ⌥Q | menu | `jj-type/Tools/QRWindowController.swift`, `QRService.swift` |
| Developer tools (JSON/Base64/URI) | ⌥J | menu | `jj-type/Tools/DevToolWindowController.swift` |
| Keep awake (防休眠) | — | menu section | `jj-type/Tools/KeepAwakeService.swift` |
| Input source keeper (输入法守护) | — | menu submenu | `jj-type/Core/InputSourceKeeper.swift` |
| Network watchdog (网络守护) | — | menu submenu + settings page | `jj-type/NetWatch/` (6 files) |
| Quick launch items (global hotkey per item) | per-item | menu submenu | `jj-type/Core/HotkeyManager.swift`, `jj-type/Launcher/LaunchItem.swift` |
| Selection action bar (PopClip-style) | drag-selection (no hotkey) | settings toggle | `jj-type/SelectionAction/SelectionActionBarController.swift` |
| Finder toolbar "open terminal here" | toolbar button | — | `jj-type/Launcher/FinderTerminal.swift` |

## Key operating facts

- **Menu-bar app, no Dock icon** — `LSUIElement = true`, Bundle ID `com.aigens.jj-type`, display name JJType.
- **Explicit entry point** — `jj-type/App/main.swift`; the `@main` AppKit bootstrap is broken on the macOS 26 beta / Xcode 26.1 toolchain and must not be switched back.
- **Everything defaults to MainActor** — `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES`; C callbacks (Carbon) hop via `MainActor.assumeIsolated`; heavy work (capture, OCR, JSON parse, flattening) is `nonisolated` or detached.
- **API keys live only in Keychain** (service `com.aigens.jj-type.provider`, account = provider UUID); UserDefaults (`jjtype.*`) holds non-secret settings.
- **Current version:** 1.13.1 (per `project.pbxproj` `MARKETING_VERSION`).

## Gotchas to know before editing

- The version lives in **two build settings that must agree** (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`); every behavior change requires a version bump and a `CHANGELOG.md` entry (see [Build & release](/openwiki/operations/build-release.md)).
- The NetWatch (network watchdog) module binds probes to the physical interface (`--interface`) so full-tunnel VPNs never mask the real link state; see [Network watchdog](/openwiki/capability/network-watchdog.md).
- Never `git commit`/`git push` — the user commits manually.
- New UI must use the shared `Theme` design system, not hand-rolled colors.
- Do not hand-edit the app icon PNGs — regenerate via `build-support/make-icon.swift`.
- The Finder-terminal flow **cannot be diagnosed from `log show`** — use `~/Library/Logs/JJType/finder-terminal.log`.

## Backlog

None — all major areas of the repository are documented in this wiki. Minor gaps that could be expanded later: unit-test strategy (there are no test targets yet; runtime verification is manual via a real GUI session + Accessibility grant), and publish/notarization (pending a distribution channel decision).