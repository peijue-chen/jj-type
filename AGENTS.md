# AGENTS.md — jj-type

Native macOS (AppKit) menu-bar app: AI-powered select-text translation + English
grammar correction via user-configured OpenAI-compatible endpoints.

## Project Facts

- **Platform:** macOS 14.0+ / Swift 5 language mode / AppKit (no SwiftUI, no storyboards — all UI programmatic)
- **App type:** LSUIElement menu-bar app (no Dock icon), Bundle ID `com.aigens.jj-type`, display name **JJType** (`CFBundleName`/`CFBundleDisplayName`; target/product stay `jj-type`)
- **Dependencies:** ZERO third-party. System frameworks only: AppKit, Carbon (global hotkeys), CoreGraphics (CGEvent synthetic ⌘C/⌘V), Security (Keychain), URLSession, NaturalLanguage, ApplicationServices
- **Xcode project:** uses `PBXFileSystemSynchronizedRootGroup` — files dropped into `jj-type/` (any subfolder) are compiled automatically; **do NOT hand-register new sources in project.pbxproj**
- **Concurrency:** build sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Everything defaults to MainActor; C callbacks (Carbon) must be `nonisolated` and hop via `MainActor.assumeIsolated`
- **Source layout** (2026-11 reorg): feature folders under `jj-type/` — `App/` (entry + AppDelegate), `Core/` (storage/hotkey/AI client), `Settings/` (settings window + recorder + Theme), `Translate/`, `Launcher/`, `ClipboardHistory/`, `ScreenCapture/` (14 files), `SelectionAction/`, `Tools/` (QR/eyedropper/keep-awake), `Permissions/`. `Info.plist`, `Assets.xcassets/`, `AppIcon.icns` stay at `jj-type/` root (the plist has a membership exception keyed to that path)
- **Design system:** `jj-type/Settings/Theme.swift` — shared type scale, `card()` grouped containers (System-Settings-style rounded cards, `updateLayer`-driven so light/dark both work), `IconTileView` (gradient SF-Symbol tiles), primary/secondary button factories. New UI MUST use Theme instead of hand-rolled colors
- **App icon:** generated, not drawn by hand — `build-support/make-icon.swift` renders `icon_1024.png` (indigo→violet squircle + "JJ" wordmark + yellow text cursor) via CoreGraphics; the `.iconset`/`.icns` are built from it (sips + iconutil into `jj-type/AppIcon.icns`). To change the icon, edit the script and regenerate — never hand-edit the PNGs

## Module Map

| File | Responsibility |
|------|----------------|
| `jj-type/Settings/Theme.swift` | Shared design system: type scale, `card()` grouped rounded containers, `IconTileView` gradient symbol tiles, primary (accent-filled) / secondary button factories, hint & form-label styles — the single source of visual truth |
| `jj-type/App/AppDelegate.swift` | Status item menu, hotkey wiring, capture → AI → panel pipeline; keep-awake menu section; clipboard-history toggle + QR generate/pin flows; AI quick-action execution (`runQuickAction`, latest-wins) |
| `jj-type/Core/HotkeyManager.swift` | Carbon RegisterEventHotKey; `Hotkey` Codable (UserDefaults); built-in ids 1–8 (翻译 ⌥D / 纠正+翻译 ⌥E / 截图 ⌘⇧2 / 启动器 ⌥O / 剪贴板历史 ⌥V / 取色 ⌥P / 二维码 ⌥Q / 开发工具 ⌥J) + launch-item slots 100–999; per-binding conflict reporting |
| `jj-type/Launcher/LaunchItem.swift` | `LaunchItem` model for the Alfred-style launcher (app / folder / file / URL), target resolution (bundle id first) and `NSWorkspace.open` |
| `jj-type/Launcher/SystemCommand.swift` | Alfred-style system rows (锁屏/睡眠/重启/关机/注销/清空废纸篓) with Latin aliases; lock = synthetic ⌃⌘Q CGEvent, sleep = `pmset sleepnow`, restart/shutdown/logout = NSAppleScript to System Events (needs the Automation grant; a -1743 surfaces a Chinese guide + deep link to the Automation pane), empty trash = Finder AppleScript **with a permission-free fallback**: activate Finder, pump the run loop until frontmost (≤1 s, then post ⇧⌥⌘⌫ kVK_Delete) — `~/.Trash` is TCC-protected (listing needs Full Disk Access), so DIRECT deletion is impossible; destructive ones confirm first; only matched on a NON-empty query |
| `jj-type/Launcher/FinderTerminal.swift` | go2shell-style "open terminal here" from the Finder toolbar: user ⌘-drags JJType.app into the toolbar; a click arrives as `applicationShouldHandleReopen` (running app) or the cold-launch tail of `applicationDidFinishLaunching`. **Critical mechanic (traced live): the open/toolbar click ACTIVATES this LSUIElement app, so at handler time `frontmostApplication` is `com.aigens.jj-type` ITSELF, not Finder** — the toolbar gate therefore accepts Finder OR self (anything else = IDE/terminal launch, skip); known trade-off: Spotlight-opening the running app is API-identical to a toolbar click and also passes the gate. AppleScript resolves selection → front Finder window → desktop (desktop fallback is REOPEN-only — at login Finder is frontmost with no windows); a selected file opens its parent; double-click guard is ONE exact match on the bundle's own container (the earlier `/Applications`-prefix block also ate legitimate "open a terminal in /Applications" clicks and is gone); opens the preferred terminal via LaunchServices (`NSWorkspace.open` with the terminal's app URL — no terminal automation permission); `TerminalApp` bundle-id registry (Terminal/iTerm2/Warp/Ghostty/WezTerm/kitty/Alacritty, legacy `io.alacritty` probed, uninstalled preference falls back Terminal-first); 0.5 s debounce; -1743 → Automation guide window; ⌥-click on the toolbar icon opens settings on the 终端 tab. Every early-exit NSLogs `[FinderTerminal]` — this flow has no other feedback, a silent no-op is undebuggable (note: `log show` may hide NSLog; run the binary with stderr captured); also **zsh's builtin `log` shadows `/usr/bin/log`** in toolchain shells |
| `jj-type/Core/TextCaptureService.swift` | Pasteboard changeCount snapshot → synthetic ⌘C → bounded poll → selected text |
| `jj-type/Tools/KeepAwakeService.swift` | 防休眠 session manager: `/usr/bin/caffeinate -d -i -s` child (indefinite by design — NO `-t` cap, user decision), 30 min / 1 h / 2 h timers, minute-level countdown tick, `terminationHandler` hops via `Task { @MainActor }` with a process-identity check (stale handlers from replaced sessions are ignored); `shutdown()` SIGTERMs + run-loop pumps at quit so no caffeinate orphan survives |
| `jj-type/ClipboardHistory/ClipboardHistoryService.swift` | Background clipboard recorder (0.5 s changeCount poll): text + PNG-normalized images only — concealed/transient markers (password managers) and file copies are skipped; own write-backs suppressed via changeCount snapshot; persists to App Support (`index.json` + `<uuid>.png`, coalesced 0.3 s IO-queue writes, 500-entry FIFO with orphan-file reconcile at launch); `paste(entry:previousApp:)` writes + transient-marks + synthetic ⌘V (Accessibility-gated, copy-only + toast without it) |
| `jj-type/ClipboardHistory/ClipboardHistoryPanelController.swift` | Clipboard history panel on the launcher skeleton (non-activating HUD, 60 ms filter debounce, 250 ms coalesced resize, reused cells, outside-click dismiss): ⏎ paste-back into the app frontmost at open, ⌘⏎ copy-only + toast, thumbnails via the service's NSCache |
| `jj-type/SelectionAction/QuickAction.swift` | `QuickAction` model (built-ins 翻译/润色/改写 with fixed UUIDs + `{text}` template — a template without the placeholder gets the text appended) + `QuickActionCatalog.builtInIds`; the persisted `aiActions` list INCLUDES the seeded built-ins (editable prompts, deletable only for customs) |
| `jj-type/SelectionAction/SelectionActionBarController.swift` | PopClip-style selection bar: global mouseDown records the drag origin (BOTH endpoints via `NSEvent.mouseLocation` — `locationInWindow` is window-relative in global monitors), mouseUp ≥12 pt away runs the FULL capture chain (AX-first + synthetic-⌘C fallback — browsers/Electron lack kAXSelectedTextAttribute, AX-only peeked worked in Xcode alone) → a non-activating chip bar under the cursor (复制 / every quick action / 二维码); every chip dismisses the bar before running its action; any outside mouseDown, Esc, or a new selection dismisses it; `setEnabled` installs/removes the monitors (settings toggle, default ON; missing AX grant surfaces the guide at launch) |
| `jj-type/Tools/EyedropperController.swift` | ⌥P screen color picker: loupe panel OFFSET from the cursor (clicks never hit the loupe), 13×13 pt `CGDisplayCreateImage` samples per mouse-move drawn nearest-neighbour with a cell grid + center crosshair; Space toggles HEX/rgb(), ⏎/click copies + CaptureToast + history (12, UserDefaults, clickable swatches); AppKit↔CG coordinates flip per screen |
| `jj-type/Tools/QRService.swift` | QR generation (`CIFilter.qrCodeGenerator`, correction M, 10 px/module CIContext render — crisp when pinned) + `nonisolated recognizeQR` (Vision `.qr`); generation pins a floating PinWindow (drag / right-click copy-save), toolbar recognition runs on the COMPOSITED selection (unlike OCR's untouched base) and offers 打开网址 for a single http(s) payload |
| `jj-type/Tools/QRWindowController.swift` | ⌥Q dedicated QR window (TranslationWindow skeleton: persisted frame, Esc/⌘W close the window only): type-to-generate (0.3 s debounce) with save-PNG (NSSavePanel) / copy-image, plus decode-from-clipboard (detached Vision, red-status errors, 打开网址 gated to single http(s) payload) |
| `jj-type/Tools/DevToolWindowController.swift` | ⌥J developer tool window (Theme cards, mono in/out): JSON pretty (key order preserved, fragments allowed) / minify, Base64 encode/decode, URI encode/decode with JS encodeURIComponent semantics (only `A-Za-z0-9-_.!~*'()` unreserved); JSON→string escapes the minified JSON into one quoted JSON string literal, string→JSON unescapes a quoted literal OR a bare escaped body (raw newlines/tabs tolerated); JSON results render as a collapsible NSOutlineView tree (`JSONNode.children` builds wrappers LAZILY per branch — folded branches allocate nothing; root-only auto-expand; type-tinted rows; 全部展开/折叠 buttons; right-click menu = 复制值 / 复制子树 JSON / 复制键) with a 树形/文本 switch; the window is `.floating` + canJoinAllSpaces and the ⌥J toggle RAISES a buried window (closes only when it is the key window); `closeAndRelease()` (Esc/⌘W/⌥J toggle) AND `windowWillClose` (red close button, deferred onClosed) clear texts + tree + prettyText, then `onClosed` makes AppDelegate drop the whole controller — a huge JSON never survives a closed window |
| `jj-type/Core/LanguageRouter.swift` | 4-way detection (english/chinese/mixed/other; CJK+Latin scan + NLLanguageRecognizer) + `TranslateMode` |
| `jj-type/Core/AIClient.swift` | OpenAI-compatible `{baseURL}/chat/completions`, 30 s, non-streaming, Codable models |
| `jj-type/Core/PromptBuilder.swift` | English JSON-contract prompts (4-way language branch) + robust `{"corrected","translation"}` extraction |
| `jj-type/Core/KeychainStore.swift` | API keys (service `com.aigens.jj-type.provider`, account = provider UUID) |
| `jj-type/Core/SettingsStore.swift` | Providers/active/hotkeys in UserDefaults (`jjtype.*` keys) |
| `jj-type/Translate/ResultPanelController.swift` | Reused non-activating floating panel: loading/error/result, replace/copy |
| `jj-type/Translate/TranslationWindowController.swift` | ⌥+D input-window mode (Bob/Easydict-style): prefill-or-type, Enter/Esc equivalents, auto-copy |
| `jj-type/Launcher/LauncherWindowController.swift` | ⌥+O Alfred-style launcher: borderless **non-activating** panel (`canBecomeKey` override, `orderFrontRegardless` — `orderFront` is a no-op while the app is inactive), **debounced** live filter (60 ms coalescing, pre-lower-cased keys + word initials, top-60 results, reused `LauncherCell`s, cached icons) over launch items **and installed apps**, search badge at the right of the input, ↑↓/⏎/esc via the field editor's command selectors, direct path/URL row and a Google-search fallback row (opens in the DEFAULT browser); the panel resize is coalesced separately (250 ms) because resizing a `.behindWindow` HUD re-blurs the desktop; the index is re-read on every open but only rebuilt when the canonical app paths changed, and configured items are deduped against the index by **resolved** path |
| `jj-type/Launcher/AppIndex.swift` | `nonisolated` scan of `/Applications`, `/System/Applications` (+ Utilities), `/System/Cryptexes/App/System/Applications` and `~/Applications`, one nesting level deep, deduped by resolved path (also exposed as `DiscoveredApp.canonicalPath`), cached with a 5-minute TTL so a newly installed app shows up without a relaunch; uses the **string** listing API (the URL one silently drops symlinks — Safari is a symlink into the cryptex); never runs on the main actor |
| `jj-type/App/main.swift` | Explicit entry point — the `@main` AppKit bootstrap is broken on this macOS 26 beta toolchain; do not switch back |
| `jj-type/Settings/SettingsWindowController.swift` | System-Settings-shaped settings (`AI 服务` / `快捷键` / `快捷启动` / `终端` / `截图` / `划词动作`): translucent **sidebar** with tinted IconTile rows + one **card-based page** per section (Theme.card), page title/subtitle swap on selection, window re-fits on page switch; provider CRUD + connection test + hotkey customization (7 built-in rows) + launch-item CRUD + capture folder/format + preferred terminal (`selectTerminalSection` lands ⌥-toolbar-clicks on that page) + 划词动作 page (selection-bar toggle, quick-action editor bound by `editingAIActionId` — built-ins editable but not deletable, form hidden until 新建/selection —, clear clipboard history); ALL three edit forms (providers / launch / actions) start hidden and appear on 新建 or row selection; the launch form is bound by **item id** (`editingLaunchId`) and that binding must never be dropped by a table selection notification; built-in hotkey conflicts are also checked against launch items; deleting a provider asks first (the Keychain key goes with it); shared footer shows the bundle version; list rows are the shared `SettingsListCell` (two-line + optional 使用中 badge) |
| `jj-type/Settings/HotkeyRecorderView.swift` | Keyboard capture field for hotkey rebinding; stores ONLY ⌘/⌥/⌃/⇧ (CapsLock / Fn / numericPad would make two identical combos compare unequal and defeat conflict detection) |
| `jj-type/Permissions/AccessibilityPermission.swift` | AXIsProcessTrusted + first-run guidance window |
| `jj-type/Permissions/AutomationPermission.swift` | Automation (Apple Events) probe + Chinese guide window; NO preflight API exists for Apple Events, so `AutomationPermission.verify(target)` sends a benign `get name` event — the first undecided probe IS the request (native prompt), denied/undecided = error; targets = Finder (empty trash, Finder-toolbar terminal) and System Events (restart/shutdown/logout), each with its own status row; guide has 打开系统设置 deep link + 验证权限 (⏎) and documents the Xcode-attribution gotcha (debug runs record the TCC grant under Xcode, not JJType — no auto-skip on show since any check may prompt) |
| `jj-type/ScreenCapture/ScreenCapturePermission.swift` | Screen Recording TCC (CGPreflight/CGRequest), settings pane, relaunch helper + guidance window |
| `jj-type/ScreenCapture/ScreenCaptureService.swift` | `nonisolated`: freezes every display via `SCScreenshotManager` (macOS 14+), crops/composites the selection |
| `jj-type/ScreenCapture/WindowSnapshot.swift` | `CGWindowListCopyWindowInfo` geometry (CG top-left → AppKit bottom-left) for window hover highlight |
| `jj-type/ScreenCapture/CaptureOverlayController.swift` | Capture session orchestration: permission, freeze, overlays, authoritative global selection, toolbar, focus restore |
| `jj-type/ScreenCapture/CaptureOverlayWindow.swift` | Borderless `.screenSaver`-level panel per display (can become key, joins all Spaces) |
| `jj-type/ScreenCapture/CaptureOverlayView.swift` | Frozen frame + dim mask + selection/handles + window hover + mouse/keyboard (no magnifier: it read as a dark blob chasing the cursor) |
| `jj-type/ScreenCapture/SelectionHandle.swift` | 8 handles: hit testing, resize/normalize/clamp geometry |
| `jj-type/ScreenCapture/CaptureToolbarController.swift` | Floating toolbar next to the selection: 9 annotation tools, undo/redo, colour + width row, tool option row (font + size for text, alpha for highlighter), recognize / pin / save / copy / close, own hover hints, edge avoidance |
| `jj-type/ScreenCapture/CaptureExporter.swift` | PNG/JPEG write to `~/Pictures/JJType/` + pasteboard copy |
| `jj-type/ScreenCapture/AnnotationTool.swift` | 9 tools, fixed 6-colour palette, 3 widths, `AnnotationItem` + eraser hit testing (global points) |
| `jj-type/ScreenCapture/AnnotationPainter.swift` | Shared CGContext/CoreText painter (view + exporter), mosaic generator, `AnnotationRenderer.compose` |
| `jj-type/ScreenCapture/TextRecognizer.swift` | `nonisolated` Vision OCR (revision 3, zh-Hans/zh-Hant + en-US, small-crop upscale, fragment dedupe, row order) |
| `jj-type/ScreenCapture/PinWindowController.swift` | Pinned window above the capture overlay: draggable, click-through while capturing, right-click menu (copy / save / close), close via button or Esc (NOT double-click) |
| `jj-type/ScreenCapture/CaptureToast.swift` | Reused HUD panel for capture feedback (OCR done, copied, pinned); never key, never eats clicks, self-dismissing |

## Build Commands

```bash
# Debug (shared scheme lives in jj-type.xcodeproj/xcshareddata/)
xcodebuild -project jj-type.xcodeproj -scheme jj-type -configuration Debug build

# Release + timestamped app copy → apps/JJType-<timestamp>.app (uses ./build derived data)
# build-release.sh produces a UNIVERSAL binary (x86_64 + arm64) via script-only ARCHS
# overrides — pbxproj stays host-arch so Xcode dev builds remain fast.
./build-release.sh

# Same build with the raw, unfiltered xcodebuild log (thousands of lines)
VERBOSE=1 ./build-release.sh
```

`build-release.sh` prints a readable log by default (version banner, per-arch
compile progress, signing, warnings/errors, elapsed time, product path) — never
`-quiet`, which makes a successful build look like nothing happened. Keep the
`-destination 'generic/platform=macOS'` flag: without it the universal build
spews "multiple matching destinations".

Signing: `CODE_SIGN_STYLE = Automatic` + `CODE_SIGN_IDENTITY = "Apple Development"`
+ personal `DEVELOPMENT_TEAM = 36RXHYW79N` (requires that team's certificate on
the machine). Publish/notarization is pending a channel decision — do not
switch back to ad-hoc `-` without user approval. Runtime verification (hotkeys,
synthetic ⌘C/⌘V, panel placement) requires a real GUI session with the
Accessibility permission granted to the built app.

Screenshot capture needs a SECOND, independent TCC grant — **Screen Recording**
(`Privacy_ScreenCapture`). macOS only applies a fresh grant at process launch, so
after authorizing the user must relaunch the app (the guide window offers a
button for exactly that). Never fall back to `CGWindowListCreateImage`.

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
- **Screenshot rules:** the overlay session owns the selection in AppKit *global*
  coordinates (bottom-left origin) and only converts at the capture boundary;
  screen freeze / crop / export must stay `nonisolated` (never on the main actor);
  every repaint is a dirty rect (`setNeedsDisplay(_:)`), never the whole 5K
  overlay. There is intentionally **no magnifier** — a 6x loupe beside the cursor
  reads as a dark blob chasing the pointer, and the dim mask alone has to carry
  the focus (only the selection is bright).
- **Window levels:** overlay = `.screenSaverWindow`, pin = +1, toolbar = +2,
  hint = +3, toast = +4. The toolbar MUST stay above the overlay: at the same
  level a canvas click raises the full-screen overlay and the toolbar vanishes
  behind it. Pins stay above the overlay so a new capture still shows them; they
  set `ignoresMouseEvents` for the duration of a session, and the capture service
  re-includes their window IDs through `exceptingWindows`. A pin drops to
  `.floating` while its right-click menu is up — a pop-up menu is level 101 and
  would otherwise render *under* the pin.
- **Feedback rules:** capture actions are never silent. OCR (success and
  no-text), copy and pin go through `CaptureToast`; only real errors use `NSAlert`.
  Double-click inside the selection = copy **and save** + close ("keep the shot")
  **with any tool active** (`Action.copyAndSave`: pasteboard via
  `CaptureExporter.copyToPasteboard`, file via `onFinish(image, copied: true)`,
  and the save handler emits ONE toast for both — never a "已复制" toast that is
  immediately overwritten). A pending inline text edit is committed first, a
  half-drawn stroke is dropped; a double click must never dismiss a pin.
  Save failures distinguish the two paths ("已复制，但保存截图失败"). A pin's
  right-click menu offers copy / save / close (right-click never closes it).
- **Annotation rules:** annotations also store *global* points and live in
  `CaptureOverlayController` (views only read them); drawing goes through the one
  `AnnotationPainter` path so the overlay and the exported bitmap can never
  diverge; flattening (`AnnotationRenderer.compose`) runs in a detached task;
  once an annotation exists the selection is locked (no move/resize/nudge). Text
  keeps its own `fontName` / `fontSize` (independent from the stroke widths, so a
  40 pt label is not tied to the 7 pt pen) and the highlighter keeps its own
  `alpha` (5 %–100 %); both are stored per item so undo/redo and export never
  diverge. The inline text editor draws **no box and no fill** — only the glyphs
  and a caret in the chosen colour — and `applyStyleToTextEditor` must push every
  colour / font / size change into the live field editor (caret, existing text and
  `typingAttributes`) immediately; the field editor's `drawsBackground` must stay
  false or an opaque box covers the screenshot, and `endTextEditing` must restore
  `drawsBackground` / `backgroundColor` / `insertionPointColor` (the field editor
  is shared app-wide). While the field editor is first responder, ⌘C / ⌘S / ⌘Z
  belong to it: `CaptureOverlayWindow.performKeyEquivalent` bails out for an
  `NSTextView` first responder, otherwise ⌘C would copy the screenshot, close the
  session and silently drop the half-typed annotation. Annotation dirty rects use
  the **measured** text width (`AnnotationPainter.measuredWidth`), never a
  per-character estimate — CJK glyphs are a full em wide.
- **OCR rules:** Vision must run off the main actor; OCR uses the *unannotated*
  crop, and the recognized text goes straight to the pasteboard + toast (no
  result panel). Keep the accuracy aids: upscale small crops (≤ 640 px shortest
  side, max 3x), newest revision, `.accurate`, language list filtered by runtime
  support, duplicate-fragment removal, and row clustering with CJK-aware spacing.
  Do not merge rows into paragraphs — it corrupts form labels and table rows.
- **Performance rules:** reuse the result panel (never re-create windows); polling
  must be bounded (interval + deadline) and NSPasteboard reads stay on the main
  queue (main-thread-affine API) via async ticks — never block the main thread;
  cancel superseded Tasks (latest-wins); single shared static URLSession
  (`AIClient.session`); write UserDefaults only on change; mosaic pixelation of a
  frozen frame runs in a detached task (picking the tool must not block the UI).
- **Implicitly-unwrapped optionals (`!`)** are forbidden in production paths.
  Exception: the NSWindowController convenience-init bootstrap pattern
  (`SettingsWindowController.store`) — assigned before first use, documented.
- **Privacy note (known trade-off):** while the result panel is visible, a global
  keyDown monitor runs to support Esc dismissal without focus. It is removed on
  dismiss and never logs or forwards events. Do not extend its scope.
- **NEVER `git commit` / `git push`** — the user commits manually.
- Commit message convention (when the user asks to commit):
  `<type>(<scope>): <subject>` — English, imperative, ≤72 chars.

## Versioning & Changelog

**Every code change ships with a version bump AND a `CHANGELOG.md` entry.**
Do not bundle an unversioned fix into a later release.

- **Version is three numbers, `MAJOR.MINOR.PATCH`** (never `1.0`):
  - `PATCH` +1 — bug fix / refactor, no user-visible behavior change
  - `MINOR` +1 — new feature or user-visible behavior change (PATCH back to 0)
  - `MAJOR` +1 — incompatible change / milestone release
- **Where the version lives** (change both, they must agree):
  `MARKETING_VERSION` (Debug + Release in `project.pbxproj`) and
  `CURRENT_PROJECT_VERSION` (build number, +1 on every release). `Info.plist`
  references them as `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` —
  never hard-code a version string in Swift; read it from the bundle
  (`SettingsWindowController.versionText` renders `JJType 1.1.0 (2)`).
- **`CHANGELOG.md`** is the human-readable "what changed": newest release on
  top, `## [x.y.z] — YYYY-MM-DD`, grouped as `Added` / `Changed` / `Fixed` /
  `Removed`. Write what the user sees (Chinese, like the UI), not the diff.
- **Procedure for any task that changes behavior:** pick the bump → update
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` → add the CHANGELOG section →
  build → done. A CHANGELOG entry without the matching build-setting change (or
  the reverse) is a defect.
