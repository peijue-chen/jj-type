---
type: Capability
title: Settings Window, Theme & Permission Guides
description: The System-Settings-style settings window with its nine pages and form-binding gotchas, the shared Theme design system, and the Accessibility / Automation / Screen-Recording permission flows.
tags: [jjtype, settings, theme, permissions, tcc]
timestamp: "2026-12-07"
---

# Settings, Theme & Permissions

## Settings window

`SettingsWindowController` (`jj-type/Settings/SettingsWindowController.swift`, ~74 KB, the largest file) reproduces macOS System Settings: a translucent **sidebar** (208 pt) with tinted `IconTileView` rows + one card-based page per section (540 pt): **通用 / AI 服务 / 快捷键 / 快捷启动 / 终端 / 截图 / 划词动作 / 输入法 / 网络守护**. Page title/subtitle swap on selection; the window re-fits on page switch; a shared footer renders the bundle version (`JJType 1.13.0` style) from `CFBundleShortVersionString`/`CFBundleVersion`.

Each page is a vertical stack of `Theme.card()` groups. All three edit forms (AI providers / launch items / quick actions) **start hidden** and appear only on 新建 or row selection.

### Form-binding gotchas (the expensive ones)

- **`editingLaunchId` caching** — after `reloadData()`, AppKit lazily dispatches a "selection cleared" notification that used to wipe the in-progress edit (1.2.1 bug: "添加始终失败"). The form binding is now keyed to the item id, selection notifications never drop it, and `selectedLaunchItem` reads the table live as fallback. **Never drop the cached-id binding for a table selection notification.**
- **`editingAIActionId`** — the quick-action editor is bound the same way; built-ins (fixed UUIDs) are editable but not deletable (enforced in `SettingsStore.deleteAIAction`); the form stays hidden until 新建/selection.
- **Provider deletion asks first** — the Keychain key goes with the provider and is unrecoverable; delete always confirms.
- **`HotkeyRecorderView`** stores ONLY ⌘/⌥/⌃/⇧ modifiers — CapsLock/Fn/numericPad would make two identical combos compare unequal and defeat conflict detection. Built-in hotkey conflicts are also checked against launch items, and ⌥Space is deliberately rejected (Alfred).

### 通用 page — launch at login (1.9.0)

The 通用 settings page provides the launch-at-login toggle. It is backed by `LaunchAtLoginService` (`jj-type/Core/LaunchAtLoginService.swift`) which wraps `SMAppService.mainApp` — the system login items database is the single source of truth. Four states render differently: `.enabled`, `.notRegistered`, `.requiresApproval` (user turned it off in System Settings), and `.unavailable`. The page warns if the app is not in `/Applications` (the login item records the current bundle path). Registration errors surface verbatim in red text.

### Accent color (1.9.0)

The interface accent color was changed from the system highlight color (default blue) to `Theme.accent` — the indigo→violet gradient from the app icon. Affected elements: result panel labels and buttons, translation window primary button, settings primary buttons/hotkey values/selected rows, capture toolbar and selection frame, eyedropper background.

### 输入法 page — input source keeper (1.11.0)

Controls `InputSourceKeeper` (`jj-type/Core/InputSourceKeeper.swift`), which re-selects a user-chosen input method when macOS falls back to ABC on app switch. Two modes: **切换 App 时纠正** (correct only on app switch) and **始终纠正** (also undoes manual ABC switches inside the same app). Falls back to Sogou when no target is chosen. The keeper stays inert if the target source is not installed/enabled — the page explains why. Designed for third-party IMEs that are not fully registered with the system and lose focus on app switch.

### 网络守护 page — network watchdog (1.12.0)

Configures `NetWatchService` (`jj-type/NetWatch/`), a network watchdog that detects outages and runs automated recovery: switch to backup Wi-Fi, restart VPN, and/or launch a specified app. Four cards on the page:

- **Status + toggle**: on/off switch, current phase, last-check time, heartbeat timestamp, 立即检查 and 立即切换备用网络 buttons.
- **Backup Wi-Fi**: SSID, password (Keychain-backed per-SSID), interface override, and Wi-Fi current-status readout + detection button.
- **Detection + VPN + app**: check interval, outage threshold, switch cooldown, overseas/domestic probe URLs, VPN app path picker, VPN grace/wait times, and the app to relaunch after recovery.
- **Webhook + heartbeat**: webhook URL, success/failure notify toggles, heartbeat enable + interval.

The page implements **input-while-editing** persistence — every field writes on edit, switching pages does not overwrite in-progress edits, and leaving the page ends editing. If an SSID is changed, the old password is never written under the new name (prevents Keychain corruption of unrelated networks). See [Network watchdog](/openwiki/capability/network-watchdog.md) for full architecture.

## Theme design system

`Theme.swift` is the single source of visual truth — **new UI must use it, not hand-rolled colors**:

- **Type scale**: `pageTitle()` 22 pt bold, `sectionTitle()` 13 pt semibold, `body()`, `bodyMedium()`, `caption()`, `mono()`.
- **CardView**: 10 px radius, 14 px padding, `updateLayer`-driven fill/border (labelColor at 5%/8% alpha) so light/dark both work; hairline `NSBox` separators.
- **IconTileView**: rounded-square gradient tile (SF Symbol + vertical gradient, white contentTint) — the sidebar signature, with per-page theme colors (AI 服务·紫 / 快捷键·橙 / 快捷启动·蓝 / 终端·绿 / 截图·粉 / 划词动作·青 / 输入法·深蓝 / 网络守护·红).
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
- Wi-Fi passwords for the network watchdog use a **separate Keychain service** (`com.aigens.jj-type.netwatch`) — never mixed with AI provider keys (`com.aigens.jj-type.provider`). Each password is stored under its SSID as the account name.

## Selection bar (划词动作)

`SelectionActionBarController` is the PopClip-style chip bar: a global mouseDown monitor records the drag origin (both endpoints via `NSEvent.mouseLocation` — `locationInWindow` is window-relative in global monitors); a mouseUp ≥12 pt away runs the full capture chain (AX-first + synthetic-⌘C fallback) and shows chips (复制 / every quick action / 二维码) under the cursor. Every chip dismisses the bar before running; any outside mouseDown, Esc, or a new selection dismisses it. Enabled by default via settings toggle; it needs no permission for mouse monitors, but reading selection via AX does — a missing grant surfaces the Accessibility guide. The bar and the result panel are mutually exclusive (`AppDelegate` dismisses the bar before showing the panel).

A **dedicated keyboard shortcut** (default ⌥S) can show the bar manually (1.8.1) — useful in browsers/Electron apps where passive selection detection cannot read the selected text. When the "快捷键直接翻译" setting is enabled (1.9.0), ⌥S skips the bar entirely and translates the selection directly.