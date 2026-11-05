---
type: Capability
title: Settings Window, Theme & Permission Guides
description: The System-Settings-style settings window with its six pages and form-binding gotchas, the shared Theme design system, and the Accessibility / Automation / Screen-Recording permission flows.
tags: [jjtype, settings, theme, permissions, tcc]
timestamp: "2026-11-05T10:32:00+08:00"
---

# Settings, Theme & Permissions

## Settings window

`SettingsWindowController` (`jj-type/Settings/SettingsWindowController.swift`, ~74 KB, the largest file) reproduces macOS System Settings: a translucent **sidebar** (208 pt) with tinted `IconTileView` rows + one card-based page per section (540 pt): **AI 服务 / 快捷键 / 快捷启动 / 终端 / 截图 / 划词动作**. Page title/subtitle swap on selection; the window re-fits on page switch; a shared footer renders the bundle version (`JJType 1.8.0 (33)` style) from `CFBundleShortVersionString`/`CFBundleVersion`.

Each page is a vertical stack of `Theme.card()` groups. All three edit forms (AI providers / launch items / quick actions) **start hidden** and appear only on 新建 or row selection.

### Form-binding gotchas (the expensive ones)

- **`editingLaunchId` caching** — after `reloadData()`, AppKit lazily dispatches a "selection cleared" notification that used to wipe the in-progress edit (1.2.1 bug: "添加始终失败"). The form binding is now keyed to the item id, selection notifications never drop it, and `selectedLaunchItem` reads the table live as fallback. **Never drop the cached-id binding for a table selection notification.**
- **`editingAIActionId`** — the quick-action editor is bound the same way; built-ins (fixed UUIDs) are editable but not deletable (enforced in `SettingsStore.deleteAIAction`); the form stays hidden until 新建/selection.
- **Provider deletion asks first** — the Keychain key goes with the provider and is unrecoverable; delete always confirms.
- **`HotkeyRecorderView`** stores ONLY ⌘/⌥/⌃/⇧ modifiers — CapsLock/Fn/numericPad would make two identical combos compare unequal and defeat conflict detection. Built-in hotkey conflicts are also checked against launch items, and ⌥Space is deliberately rejected (Alfred).

## Theme design system

`Theme.swift` is the single source of visual truth — **new UI must use it, not hand-rolled colors**:

- **Type scale**: `pageTitle()` 22 pt bold, `sectionTitle()` 13 pt semibold, `body()`, `bodyMedium()`, `caption()`, `mono()`.
- **CardView**: 10 px radius, 14 px padding, `updateLayer`-driven fill/border (labelColor at 5%/8% alpha) so light/dark both work; hairline `NSBox` separators.
- **IconTileView**: rounded-square gradient tile (SF Symbol + vertical gradient, white contentTint) — the sidebar signature, with per-page theme colors (AI 服务·紫 / 快捷键·橙 / 快捷启动·蓝 / 终端·绿 / 截图·粉 / 划词动作·青).
- **Buttons**: `primaryButton()` accent-filled white semibold; standard rounded buttons with optional leading SF Symbol.
- **Helpers**: `hint()`, `sectionHeader()`, `formLabel()`, and the menu-bar "JJ▮" template image.

## Permission guides

Three permissions gate the app's core flows, each with a dedicated guide window (Chinese) and a system-dialog-first approach:

| Permission | Check | Request/probe | Guide & gotchas |
|---|---|---|---|
| **Accessibility** (`AccessibilityPermission.swift`) | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions(promptKey: true)` | First-run guidance; missing grant surfaces the guide at launch when the selection bar is enabled. Gates synthetic ⌘C/⌘V and selection capture. |
| **Automation / Apple Events** (`AutomationPermission.swift`) | **No preflight API exists** — `verify(target)` sends a benign `get name` event; the first undecided probe **IS the request** (native prompt) | same as check | Guide lists two targets: **Finder** (empty trash, toolbar terminal) and **System Events** (restart/shutdown/logout), each with its own status row, 打开系统设置 deep link + 验证权限. **Xcode attribution gotcha**: debug runs record the TCC grant under Xcode, not JJType. |
| **Screen Recording** (`ScreenCapturePermission.swift`) | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` | Guide + relaunch button — macOS applies the grant only at process launch. Gates capture AND the eyedropper. |

All guides' 打开系统设置 tries the modern `x-apple.systempreferences:…` deep link first with a legacy fallback.

### Info.plist keys that matter

- `LSUIElement = true` — menu-bar app, no Dock icon.
- `NSAppleEventsUsageDescription` — **required** for any Apple-event use (empty trash, Finder terminal, system commands). Without it, macOS silently denies every event (-1743) and never shows the prompt; its absence was the root cause of the Finder-toolbar terminal silently failing on every click (CHANGELOG 1.8.0).
- `CFBundleShortVersionString`/`CFBundleVersion` reference `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` — never hard-code versions in Swift.

## Selection bar (划词动作)

`SelectionActionBarController` is the PopClip-style chip bar: a global mouseDown monitor records the drag origin (both endpoints via `NSEvent.mouseLocation` — `locationInWindow` is window-relative in global monitors); a mouseUp ≥12 pt away runs the full capture chain (AX-first + synthetic-⌘C fallback) and shows chips (复制 / every quick action / 二维码) under the cursor. Every chip dismisses the bar before running; any outside mouseDown, Esc, or a new selection dismisses it. Enabled by default via settings toggle; it needs no permission for mouse monitors, but reading selection via AX does — a missing grant surfaces the Accessibility guide. The bar and the result panel are mutually exclusive (`AppDelegate` dismisses the bar before showing the panel).