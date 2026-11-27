---
type: Capability
title: Network Watchdog (NetWatch)
description: The NetWatch module that detects network outages, automatically switches to backup Wi-Fi, restarts VPN, relaunches apps, and sends webhook notifications — all from the menu bar.
tags: [jjtype, netwatch, networking, vpn, wifi, webhook]
timestamp: "2026-12-07"
---

# Network Watchdog (NetWatch)

Introduced in 1.12.0, NetWatch is a state-machine-driven network watchdog that lives in the menu bar. When the network goes down, it runs a configurable recovery chain: **switch to backup Wi-Fi → wait for connectivity → (optional) restart VPN → (optional) launch an app → webhook notification**.

NetWatch is controlled by `NetWatchService.shared` (`jj-type/NetWatch/NetWatchService.swift`), invoked by `AppDelegate` during startup. The status menu submenu shows the current phase, last check time, and manual-action buttons.

## Source files

All under `jj-type/NetWatch/`:

| File | Responsibility |
|---|---|
| `NetWatchService.swift` | MainActor state machine; one timer drives everything |
| `NetWatchConfig.swift` | Persisted configuration (UserDefaults JSON); Wi-Fi password in Keychain |
| `NetWatchProbe.swift` | `nonisolated` blocking probes (ping, curl, networksetup) |
| `NetWatchWebhook.swift` | Zoho Cliq-compatible webhook sender with offline queue |
| `NetWatchSettingsPage.swift` | Settings page UI — 4 cards in a scroll container |
| `NetWatchLog.swift` | Async-friendly logging via `OSLog` |

## State machine

`NetWatchPhase` drives all decisions:

| Phase | Meaning |
|---|---|
| `.disabled` | Watchdog turned off; no timer runs |
| `.healthy` | All probe targets reachable; periodic heartbeat may fire |
| `.networkDown(since:)` | Outage detected but before outage threshold; timer counts up |
| `.switching` | Actively joining backup Wi-Fi / waiting for link |
| `.recovering` | Network came back after a switch; running VPN restart + app launch chain |
| `.vpnDown(since:)` | VPN tunnel broken but local network works; counts up to threshold |
| `.failed(reason:)` | Recovery chain exhausted or unrecoverable error |

### Core flow

```
timer tick → probe (interface-bound) → connectivity verdict →
  .overseasOK  → reset outage/VPN timers → maybe heartbeat
  .localOnly   → count VPN-down timer → if exceeded → restart VPN
  .noLink      → count outage timer → if exceeded → switch Wi-Fi →
                  wait → if still down → cooldown →
                  if back → recover (VPN + app + webhook)
```

One `NSTimer` on the main actor fires every `checkInterval` (default 30 s). Blocking work (ping, curl, `networksetup`, `ifconfig`, `scutil`, `pgrep`, `kill`) runs on a detached task; state mutations stay on the main actor.

## Three-layer connectivity

`NetWatchProbe.Connectivity` models three distinct verdicts — the old boolean check could not tell them apart:

| Verdict | Detection | Action |
|---|---|---|
| `.noLink` | Interface has no active status, or gateway ping fails over the physical interface | Switch to backup Wi-Fi immediately |
| `.localOnly(domestic:, overseas:)` | Domestic URL (default `https://ip.cn/`) succeeds but overseas URL (default `https://www.google.com.hk/`) fails | Do NOT switch Wi-Fi — the physical link is fine; restart VPN instead |
| `.overseasOK(detail:)` | Overseas URL returns any HTTP status over the physical interface | Healthy; no action |

**Key design rule**: probes bind to the physical interface (`ping -I en0`, `curl --interface en0`) so a full-tunnel VPN that owns the default route never masks the real link state. The old VPN-status-only (`scutil --nc status`) check was replaced because non-system VPN clients (or networks that are themselves VPNs) would not show up there.

## VPN restart logic

When `.localOnly` persists past the VPN grace threshold, the watchdog:

1. **Quit**: sends `--quit` to OpenVPN Connect's GUI process with a 15 s timeout; upgrades to `SIGKILL` if the GUI hangs.
2. **Purge**: finds all processes whose executable resides under the VPN app bundle (`<app>/Contents/`), not just matching the bundle name — prevents killing unrelated processes whose command line contains the bundle path.
3. **Relaunch**: opens the full bundle path (not `open -a <name>` which silently fails).
4. **Wait**: polls connectivity until `vpnWaitSeconds` elapses; skips the check tick while waiting.

Failed restarts use **exponential backoff** (2 → 4 → 8 → ... → max 30 min) to avoid hammering the system.

## Heartbeat (1.13.0, hardened in 1.13.1)

Periodic "still running" webhook that fires on the normal probe tick — **no dedicated timer**. `heartbeatClock` measures elapsed time from the last anchor; once it exceeds `heartbeatInterval` (default 7200 s), one heartbeat is sent and the clock advances to now. Failures use a 5-minute retry window only (never enter the offline queue — a stale "still running" message is misleading hours later).

**Anchor rules (1.13.1)** — these exist because the heartbeat used to stall silently:

- **Persisted** to `UserDefaults` (`netWatch.heartbeatClock`). An app restart (kill -9, update reload, quit/relaunch) no longer restarts the count. An anchor older than 2 × interval is discarded on start, because reporting "still running" for a process that was not running is a lie.
- **Re-anchored only on a REAL recovery** — `NetWatchPhase.isOutage` (networkDown / switching / failed / vpnDown / recovering) returning to healthy. A brief `localOnly`/`vpnDown` blip no longer resets the window; with a 2 h interval and frequent VPN hiccups, that reset was postponing the heartbeat forever.
- **Re-anchored on wake** (`NSWorkspace.didWakeNotification` → `handleWake()`), which also probes immediately. A sleeping `Timer` coalesces missed fires into one, so a nap crossing the interval used to deliver a single stale heartbeat right after waking — the notorious "one notification at 2 am".
- **Shortened interval** takes effect at once: re-anchor only if the new interval has not already elapsed, so an already-due heartbeat is not postponed.
- Every rejection is logged **once per change** (`heartbeat skipped: <reason>`), so a stalled heartbeat is visible in `netwatch.log`. The old silent `guard` made this undebuggable.

**Outage anchor (1.13.1)**: `outageStart` is also persisted (`netWatch.outageStart`, 24 h stale limit) so a process restart mid-outage does not restart the 断网判定 countdown — the backup-Wi-Fi switch resumes immediately instead of waiting another full threshold. `stop(preservingOutage:)` distinguishes a user disabling the watchdog (clears both anchors) from the process going away (`AppDelegate.applicationWillTerminate` passes `true`, keeping them).

## Offline queue

`NetWatchWebhook` maintains a thread-safe in-memory queue (`NSLock`-guarded, max 50 entries) that persists to `~/Library/Application Support/JJType/NetWatchQueue.json`. Messages accumulate while the network is down and are flushed in order on the next successful probe. Heartbeat messages bypass the queue (use `send` not `deliver`).

## Keychain isolation

Wi-Fi passwords live in a **separate Keychain service** (`com.aigens.jj-type.netwatch`) from AI provider keys (`com.aigens.jj-type.provider`). Each password is stored under its SSID as the account name. If the user changes the SSID in settings, the old password is never silently written under the new name — that would corrupt another network's key.

## Persistence

- **Config**: `NetWatchConfig` persisted as JSON in UserDefaults under `jjtype.netWatch.config`.
- **Wi-Fi password**: Keychain service `com.aigens.jj-type.netwatch`, account = SSID.
- **Webhook queue**: `~/Library/Application Support/JJType/NetWatchQueue.json`.

## Settings page gotchas

- **All fields save on edit** — switching pages never overwrites in-progress edits; leaving the page ends editing.
- **Empty numeric fields** revert to the previous valid value instead of collapsing to the minimum.
- **Missing selected app** in the dropdown is preserved and labelled "(未找到)" rather than silently cleared.
- **If the watchdog turns Wi-Fi on to switch, and the switch fails**, Wi-Fi is restored to its previous state (prevents idle radio drain on a machine that normally uses wired ethernet).

## Dependencies on other systems

- The watchdog uses `KeepAwakeService` implicitly: during a lock-screen session the watchdog keeps running because `-i -s` prevents system sleep even without `-d`. See [Utilities](/openwiki/capability/tools.md) for display-sleep policy.
- The menu submenu is rebuilt whenever `NetWatchService.onStatusChanged` fires, which is wired to `AppDelegate.rebuildStatusMenu()`.
