---
type: Operations
title: Build, Versioning & Release
description: How to build JJType (Debug / universal Release), the versioning + CHANGELOG rules every change must follow, the app-icon pipeline, and the scheduled OpenWiki CI workflow.
tags: [jjtype, build, release, versioning, ci]
timestamp: "2026-11-05T10:34:00+08:00"
---

# Build, Versioning & Release

## Project facts

- **Platform:** macOS 14.0+; Swift 5 language mode; AppKit only (no SwiftUI, no storyboards). Bundle ID `com.aigens.jj-type`, LSUIElement menu-bar app.
- **Dependencies:** zero third-party. System frameworks only.
- **Synchronized sources:** the Xcode project uses `PBXFileSystemSynchronizedRootGroup` — files dropped into `jj-type/` are compiled automatically; never hand-register sources in `project.pbxproj`.
- **Concurrency flags:** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES` (see [Architecture overview](/openwiki/architecture/overview.md)).

## Build commands

```bash
# Debug (shared scheme lives in jj-type.xcodeproj/xcshareddata/)
xcodebuild -project jj-type.xcodeproj -scheme jj-type -configuration Debug build

# Release + timestamped app copy → apps/JJType-<timestamp>.app (uses ./build derived data)
./build-release.sh

# Same build with the raw, unfiltered xcodebuild log (thousands of lines)
VERBOSE=1 ./build-release.sh
```

`build-release.sh` (`/build-release.sh`) builds a **universal binary (x86_64 + arm64)** via script-only `ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO` overrides — `project.pbxproj` stays host-arch so Xcode dev builds remain fast. It uses `-destination 'generic/platform=macOS'` (required, otherwise "multiple matching destinations") and prints a readable filtered log by default: version banner, per-arch compile progress, signing, warnings/errors verbatim, elapsed time, and the product path — never `-quiet`, which makes a successful build look like nothing happened. Output goes to `apps/<YYYYMMDD-HHMM>/JJType.app`.

**Signing:** `CODE_SIGN_STYLE = Automatic` + `CODE_SIGN_IDENTITY = "Apple Development"` + personal `DEVELOPMENT_TEAM = 36RXHYW79N` (requires that team's cert on the machine). Publish/notarization is pending a channel decision — do not switch back to ad-hoc `-` without user approval.

**Runtime verification** (hotkeys, synthetic ⌘C/⌘V, panel placement) requires a real GUI session with Accessibility granted to the built app; screenshot capture needs a second, independent Screen Recording grant applied at relaunch.

## Versioning & CHANGELOG — mandatory procedure

Every code change ships with a version bump AND a `CHANGELOG.md` entry. Do not bundle an unversioned fix into a later release.

- **Version is three numbers `MAJOR.MINOR.PATCH`**:
  - `PATCH` +1 — bug fix / refactor, no user-visible behavior change
  - `MINOR` +1 — new feature or user-visible behavior change (PATCH back to 0)
  - `MAJOR` +1 — incompatible change / milestone release
- **Where the version lives** (both must agree): `MARKETING_VERSION` (Debug + Release in `project.pbxproj`) and `CURRENT_PROJECT_VERSION` (build number, +1 every release). `Info.plist` references them as `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` — never hard-code a version string in Swift. Read current values from the bundle (`versionText` renders e.g. `JJType 1.8.0 (33)`).
- **`CHANGELOG.md`**: newest release on top, `## [x.y.z] — YYYY-MM-DD`, grouped `Added` / `Changed` / `Fixed` / `Removed`. Write what the user sees (Chinese, like the UI), not the diff.
- **Procedure for any behavior-changing task:** pick the bump → update `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` → add the CHANGELOG section → build → done. A CHANGELOG entry without the matching build-setting change (or the reverse) is a defect.

Release history at a glance (CHANGELOG.md): 1.0 baseline menu-bar translation → 1.1 settings footer + Swift 6 concurrency fixes → 1.2 launcher + quick-launch → 1.3 search fallbacks + index TTL → 1.4 system commands + empty-trash fallback chain → 1.5 Finder toolbar terminal + automation guide → 1.6 selection bar, clipboard history, QR, eyedropper, keep-awake, quick AI actions → 1.7 visual overhaul + feature-folder source reorg → 1.8 dev tool window, clipboard single-item delete, startup speed, Finder terminal root-cause fix (NSAppleEventsUsageDescription).

## App icon pipeline

The icon is **generated, never hand-drawn**: `build-support/make-icon.swift` renders `icon_1024.png` (indigo→violet→azure gradient squircle + "JJ" wordmark + warm-yellow text cursor) via CoreGraphics; sips + iconutil build the `.iconset`/`.icns` → `jj-type/AppIcon.icns` (referenced via `CFBundleIconFile` in Info.plist). To change the icon, edit the script and regenerate — never hand-edit the PNGs. The asset-catalog route (single-size AppIcon.appiconset) is NOT used: Xcode 26.1 actool rejects every documented single-size variant with "unassigned child". Menu-bar icon is the SF Symbol `translate` with `isTemplate = true`.

## CI / automation

`.github/workflows/openwiki-update.yml` runs **scheduled OpenWiki documentation updates** (daily 08:00 UTC + workflow_dispatch) on ubuntu-latest: installs `openwiki` globally, runs `openwiki code --update --print` with OpenRouter provider (model `z-ai/glm-5.2`), and opens a PR (`openwiki/update`) that includes `openwiki/`, `AGENTS.md`, `CLAUDE.md`, and the workflow itself. It requires the `OPENROUTER_API_KEY` and `LANGSMITH_API_KEY` secrets. This is the same update this wiki was generated by; do not hand-edit generated wiki pages, prefer letting the workflow regenerate (or ask for a targeted doc change in chat).

## Gotchas for maintainers

- `mode.json` at repo root is a local reference file — never commit it, never copy its key anywhere (secrets live in Keychain only).
- Never `git commit` / `git push` — the user commits manually. Commit message convention (when asked): `<type>(<scope>): <subject>` — English, imperative, ≤72 chars.
- Comments in English; user-facing UI text in Chinese.
- Implicitly-unwrapped optionals (`!`) are forbidden in production paths, except the documented `SettingsWindowController.store` convenience-init bootstrap.