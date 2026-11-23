---
type: Capability
title: Utilities — Keep Awake, Eyedropper, QR, Dev Tools, Clipboard History
description: "JJType's background utilities: caffeinate keep-awake sessions, the ⌥P eyedropper, QR generation/recognition windows, the ⌥J developer tool window, and the clipboard history recorder."
tags: [jjtype, tools, clipboard, qr, devtools]
timestamp: "2026-12-07"
---

# Utilities

`jj-type/Tools/` and `jj-type/ClipboardHistory/` host the standalone utilities. They share recurring patterns: **generation counters / tokens** guard stale async work, **latest-wins** cancellation, explicit frame persistence over autosave, `CaptureToast` for non-silent feedback, and Esc/⌘W closing only the window (never the app).

## Keep awake (防休眠)

`KeepAwakeService` spawns `/usr/bin/caffeinate -d -i -s` as a child — **indefinite by design, no `-t` cap** (product decision). Menu offers 30 min / 1 h / 2 h timers with a minute-level countdown; the status icon swaps to a coffee cup while active. `shutdown()` SIGTERMs + run-loop pumps at quit so no orphan survives; termination handlers hop via `Task { @MainActor }` with a process-identity check so stale handlers from replaced sessions are ignored.

**Display sleep policy (1.12.0)**: A new 允许息屏 toggle (default ON) in the menu submenu controls whether `caffeinate` gets the `-d` flag. When ON, only `-i -s` are passed — the display turns off normally, the lock screen is not brightened, and the network watchdog (NetWatch) keeps running in the background. When OFF, `-d` is added, keeping the screen on at all times. The `-d` flag asserts `PreventUserIdleDisplaySleep`, which means the lock screen content is visible to anyone walking past, so the default is OFF for `-d`. Toggling the policy replaces the `caffeinate` session and resets the countdown timer.

## Eyedropper (⌥P)

`EyedropperController` screens color under the cursor with a loupe panel **offset** from the cursor (clicks never hit the loupe). 13×13 pt `CGDisplayCreateImage` samples drawn nearest-neighbor with a cell grid + center crosshair. Cursor tracking is three-layered: a global mouseMoved monitor + a local monitor (own-window moves bypass the global stream) + a 30 fps poll with a >0.25 pt delta guard (catch-all for apps with own event taps). Space toggles HEX/rgb(); ⏎/click copies + toast + history (12 swatches in UserDefaults, clickable). Requires the Screen Recording grant; coordinates convert between AppKit bottom-left and CG top-left per screen.

## QR codes

- `QRService` — generation via `CIFilter.qrCodeGenerator` (correction M, 10 px/module raster → crisp when pinned) and recognition via `nonisolated` Vision `.qr`. Generation pins a floating `PinWindowController` (drag / right-click copy-save); toolbar recognition runs on the **composited** selection and offers 打开网址 for a single http(s) payload.
- `QRWindowController` (⌥Q) — dedicated window (TranslationWindow skeleton: persisted frame, Esc/⌘W close window only): type-to-generate with 0.3 s debounce and save-PNG/copy-image; decode from clipboard or picked image file (detached Vision, red-status errors, 打开网址 gated to exactly one http(s) payload).

## Developer tool window (⌥J)

`DevToolWindowController` is a floating, all-Spaces window with JSON / Base64 / URI tools on one page (Theme cards, mono in/out):

- JSON pretty (key order preserved, fragments allowed) / minify; JSON→string escapes minified JSON into one quoted JSON string literal; string→JSON unescapes a quoted literal or bare escaped body.
- Base64 encode/decode; URI encode/decode with JS `encodeURIComponent` semantics (only `A-Za-z0-9-_.!~*'()` unreserved).
- JSON results render as a collapsible `NSOutlineView` tree — `JSONNode.children` builds wrappers **lazily per branch**, so a 10 MB JSON never materializes unfolded branches; root-only auto-expand; type-tinted rows; 全部展开/折叠; right-click = 复制值 / 复制子树 JSON / 复制键; 树形/文本 switch.
- **Large-document support**: both text views use **TextKit 2** (`NSTextView(usingTextLayoutManager:)`) — TextKit 1 lays out the entire document on assignment (a 6 MB / 116k-line JSON costs ~2 s per layout and re-lays out on every edit). TextKit 2 lays out only what is on screen, keeping multi-MB assignment in the millisecond range. On top of that, tree-mode results skip text rendering entirely: the document is only handed to the text view when 文本 mode is opened; 复制结果 / 结果 → 输入 always read `prettyText` directly, never the view. Parse + serialize also run on a background queue so a multi-MB transform never freezes the window.
- **Memory policy**: `closeAndRelease()` (Esc/⌘W/⌥J toggle) AND `windowWillClose` (red button, deferred `onClosed`) clear texts + tree + prettyText, then `onClosed` makes AppDelegate drop the whole controller — a huge JSON never survives a closed window. The ⌥J toggle RAISES a buried window and closes only when it's the key window.

## Clipboard history (⌥V)

`ClipboardHistoryService` runs a 0.5 s `changeCount` poll on the main run loop, recording **text and PNG-normalized images only**:

- Skips concealed/transient markers (password managers) and file copies; its own write-backs are suppressed via changeCount snapshot.
- Persists to `~/Library/Application Support/JJType/ClipboardHistory/` (`index.json` + one `<uuid>.png` per image), coalesced 0.3 s serial IO-queue writes, 500-entry FIFO trim with orphan-file reconcile at launch.
- `paste(entry:previousApp:)` writes + transient-marks + synthetic ⌘V (Accessibility-gated; copy-only + toast without it).

`ClipboardHistoryPanelController` is a non-activating HUD on the launcher skeleton (60 ms filter debounce, 250 ms coalesced resize, reused cells, outside-click dismiss): ⏎ pastes back into the app frontmost **at open**; ⌘⏎ copy-only + toast; ⌥⌫ deletes a single entry (1.8.0) keeping selection adjacent. Thumbnails come from the service's NSCache. When pasting, if the previous app lost focus, it is reactivated with a 0.4 s pump before the synthetic ⌘V.