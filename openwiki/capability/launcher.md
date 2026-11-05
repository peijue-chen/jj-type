---
type: Capability
title: Launcher, System Commands & Finder Terminal
description: The ⌥O Alfred-style launcher, installed-app index, system command rows with permission fallback chains, and the Finder-toolbar open-terminal flow.
tags: [jjtype, launcher, alfred, finder, terminal]
timestamp: "2026-11-05T10:26:00+08:00"
---

# Launcher, System Commands & Finder Terminal

Three closely related pieces in `jj-type/Launcher/`: the Alfred-style launcher (`LaunchItem` + `LauncherWindowController` + `AppIndex`), Alfred-style system commands (`SystemCommand`), and the Finder-toolbar "open terminal here" flow (`FinderTerminal`).

## Launcher window (⌥O)

`LauncherWindowController` is a borderless **non-activating** panel (`canBecomeKey = true`, `canBecomeMain = false`, `.floating` level, joins all Spaces). Open via `orderFrontRegardless()` because `orderFront` is a no-op while the app is inactive; a safety-net `NSApp.activate` runs after one runloop turn if the panel never became key.

Search behavior:

- **Empty query** → configured launch items only (no installed-app noise).
- **Typed query** → scores all rows: name-prefix (3) > name-contains (2) > word-initials (2, e.g. `gc` → Google Chrome) > extra-field keywords (1); configured items and system commands get a tie-break +1. Results capped at top 60.
- **Debouncing**: 60 ms filter debounce; panel resize coalesced at 250 ms (resizing a `.behindWindow` HUD re-blurs the desktop — the 1.3.0 fix for "fast deleting is laggy").
- **Fallbacks**: `/`-`~`-slash and domain-shaped inputs (letters+TLD, IPv4) with no match → "直接打开" via the default browser; otherwise a Google-search row. Empty-space-free requirement means `1.5`/`v1.2` go to Google, not direct-open.
- Cells are reused with cached icons; generation tokens guard stale async work; rows dedupe by **resolved path**.

`LaunchItem` supports 4 target kinds (application / folder / file / URL). Apps resolve **bundle id first** (survives app moves/renames), stored path only as fallback; URL targets get `https://` prepended for bare domains; opening goes through `NSWorkspace.open`.

## App index

`AppIndex` (`nonisolated`) scans `/Applications`, `/System/Applications` (+ Utilities), `/System/Cryptexes/App/System/Applications`, and `~/Applications`, one nesting level deep, deduped by resolved path, cached with a **5-minute TTL** (new installs appear without relaunch, ~35 ms scan). It deliberately uses the **string** listing API — the URL-based `contentsOfDirectory` silently drops symlinks, which made Safari (a symlink into the cryptex) undiscoverable.

## System commands

`SystemCommand` provides Alfred-style rows for 锁屏 / 睡眠 / 重启 / 关机 / 注销 / 清空废纸篓 (with Latin aliases like `lock`, `sleep`, `reboot`, `emptytrash`); matched only on a non-empty query, destructive ones confirm first.

Permission strategies (in order):

- **锁屏** — synthetic ⌃⌘Q CGEvent (needs Accessibility, already a baseline grant).
- **睡眠** — `/usr/bin/pmset sleepnow`, no privileges.
- **重启 / 关机 / 注销** — AppleScript to System Events (Automation TCC; -1743 mapped to a Chinese guide + deep link).
- **清空废纸篓** — fallback chain: Finder `empty trash` AppleScript → on -1743, activate Finder, pump the run loop up to 1 s until frontmost, then post ⇧⌥⌘⌫ (`kVK_Delete`) at `.cgSessionEventTap`. Directly deleting `~/.Trash` was abandoned because the directory is TCC-protected (listing needs Full Disk Access) and silent failures were worse than the focus cost.

## Finder toolbar open-terminal

`FinderTerminal` implements the go2shell-style "open terminal here" flow (⌘-drag JJType.app into a Finder toolbar). It is the most traumatically-debugged flow in the app — see `AGENTS.md` and CHANGELOG 1.8.0/1.5.0:

- A toolbar click on the running app arrives as a raw `kAEReopenApplication` Apple event; `applicationShouldHandleReopen` is **not** delivered for this LSUIElement/no-window app (traced live). Cold launch is handled at the tail of `applicationDidFinishLaunching`.
- **Activation trap**: the click activates JJType itself, so at handler time `frontmostApplication` is JJType, not Finder — the gate accepts Finder **or** self and rejects everything else (IDE/terminal launches). Known trade-off: Spotlight-opening the running app is API-identical and passes the gate.
- **Double-click guard**: matches two exact paths (the bundle's container AND the bundle itself — a bundle is a directory, so file→parent fix-up doesn't apply); both sides normalized through `standardizedFileURL`.
- **-1743 handling**: per-block `try` re-raises (never swallows into the desktop fallback — that was the "every click opened Desktop" bug). Script failure → toast 「无法读取 Finder 位置」; only a resolved-but-empty result (no selection, no folder window) falls back to the Desktop on warm launches.
- **Prerequisite**: `Info.plist` must carry `NSAppleEventsUsageDescription` or macOS silently denies every event without ever prompting — the root-cause fix in 1.8.0.
- **Diagnostics**: every step goes through `FinderTerminal.note()` → `~/Library/Logs/JJType/finder-terminal.log` (256 KB rotation), because release NSLog does not reach the unified log and stderr is discarded. Also: zsh's builtin `log` shadows `/usr/bin/log`.
- Terminal resolution: user preference → iTerm2 → Terminal (with a bundle-id registry incl. Warp/Ghostty/WezTerm/kitty/Alacritty and a legacy `io.alacritty` probe); opening is plain LaunchServices — no terminal automation permission. ⌥-click on the toolbar icon opens Settings on the 终端 tab.