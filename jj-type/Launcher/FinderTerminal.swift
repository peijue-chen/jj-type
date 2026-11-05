//
//  FinderTerminal.swift
//  jj-type
//
//  "Open terminal here" from the Finder toolbar (go2shell-style): the user
//  ⌘-drags JJType.app into the Finder toolbar; clicking the icon resolves the
//  current folder (selection → front window → desktop) and opens the preferred
//  terminal there. A click on the RUNNING resident app arrives as a raw
//  `kAEReopenApplication` Apple event (AppDelegate; for this LSUIElement app
//  `applicationShouldHandleReopen` is NOT delivered — verified by log); a click
//  while it is not running cold launches it (handled at the tail of
//  `applicationDidFinishLaunching`, with NO desktop fallback — at login Finder
//  is frontmost with no windows and that must never spawn a terminal). NOTE:
//  the click ACTIVATES this LSUIElement app, so `frontmostApplication` at
//  handler time is usually the app ITSELF, not Finder — the toolbar gate
//  accepts either (see handleLaunch).
//
//  PREREQUISITE: Info.plist must contain `NSAppleEventsUsageDescription` —
//  without it macOS denies every Apple event (-1743) with NO prompt at all,
//  and the whole feature is dead.
//

import AppKit

/// Supported terminals, keyed by bundle id (survives non-/Applications
/// installs, unlike hard-coded paths). Ordered by go2shell's preference list.
enum TerminalApp: String, CaseIterable {
    case terminal = "com.apple.Terminal"
    case iterm2 = "com.googlecode.iterm2"
    case warp = "dev.warp.Warp-Stable"
    case ghostty = "com.mitchellh.ghostty"
    case wezterm = "com.github.wez.wezterm"
    case kitty = "net.kovidgoyal.kitty"
    case alacritty = "org.alacritty"

    var displayName: String {
        switch self {
        case .terminal: return "终端 (Terminal)"
        case .iterm2: return "iTerm2"
        case .warp: return "Warp"
        case .ghostty: return "Ghostty"
        case .wezterm: return "WezTerm"
        case .kitty: return "kitty"
        case .alacritty: return "Alacritty"
        }
    }

    /// Alacritty migrated its bundle id (io.alacritty → org.alacritty), so the
    /// legacy id is still probed.
    private var bundleIds: [String] {
        self == .alacritty ? [rawValue, "io.alacritty"] : [rawValue]
    }

    var appURL: URL? {
        for id in bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }

    var isInstalled: Bool { appURL != nil }

    /// The terminal to actually launch: stored preference (when still
    /// installed) → iTerm2 when present → Terminal.app (always installed).
    static var resolved: TerminalApp {
        if let raw = UserDefaults.standard.string(forKey: SettingsStore.Key.preferredTerminal),
           let preferred = TerminalApp(rawValue: raw), preferred.isInstalled {
            return preferred
        }
        return TerminalApp.iterm2.isInstalled ? .iterm2 : .terminal
    }
}

enum FinderTerminal {
    /// Debounce: a double click on the toolbar icon must open ONE terminal.
    private static var lastHandled: Date?

    // MARK: - Diagnostics
    /// NSLog is useless for this flow: a GUI app spawned by launchd has its
    /// stderr on /dev/null and, on this macOS, the message does not land in the
    /// unified log either (`log show` has no entry for the launch-time NSLog).
    /// Every step is therefore ALSO appended here, so a failed click can be
    /// diagnosed after the fact:  tail -f ~/Library/Logs/JJType/finder-terminal.log
    static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let directory = base.appendingPathComponent("Logs/JJType", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("finder-terminal.log")
    }()

    private static let logFormatter = ISO8601DateFormatter()

    /// Append one diagnostic line; rotates (truncates) above 256 KB so the
    /// file can never grow without bound.
    static func note(_ message: String) {
        NSLog("[FinderTerminal] %@", message)
        guard let data = (logFormatter.string(from: Date()) + " " + message + "\n").data(using: .utf8) else {
            return
        }
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: logURL.path))?[.size] as? Int ?? 0
        if size > 256 * 1024 {
            try? data.write(to: logURL)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Entry point from AppDelegate (reopen while running, launch when not).
    /// Diagnostics at every step: this flow is driven by a GUI event with no
    /// other feedback, so a silent no-op is otherwise undebuggable.
    static func handleLaunch(coldLaunch: Bool) {
        let now = Date()
        if let last = lastHandled, now.timeIntervalSince(last) < 0.5 {
            note("debounced (cold=\(coldLaunch ? 1 : 0))")
            return
        }
        lastHandled = now

        // Toolbar context. The open/toolbar click ACTIVATES this LSUIElement
        // app, so at handler time the frontmost app is either still Finder
        // (cold launch, before activation lands) or OURSELVES (reopen of the
        // running app) — see the 17:25 trace in the debugging session: reopen
        // arrived with frontmost = com.aigens.jj-type. Anything else (terminal
        // `open -a`, IDE launches) is not a Finder-initiated click. Known
        // trade-off: Spotlight-opening the running app is API-wise identical
        // to a toolbar click and also lands here.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let finder = "com.apple.finder"
        let own = Bundle.main.bundleIdentifier ?? ""
        note("click cold=\(coldLaunch ? 1 : 0) frontmost=\(frontmost) ax=\(AccessibilityPermission.isGranted ? 1 : 0)")
        guard frontmost == finder || frontmost == own else {
            note("skip: frontmost=\(frontmost) is neither Finder nor self")
            return
        }

        let path: String
        do {
            path = try frontFinderPath()
            note("Finder script returned '\(path)'")
        } catch let error as SystemCommandError where error.isAuthorizationFailure {
            // -1743: no Automation grant for Finder — the shared guide window
            // (system-settings deep link + per-target verification) explains it.
            note("skip: Finder automation denied (-1743), showing guide")
            AutomationGuideWindowController.shared.showIfNeeded(force: true)
            return
        } catch {
            note("skip: Finder script failed: \(error.localizedDescription)")
            CaptureToast.shared.show("无法读取 Finder 位置（检查自动化权限）",
                                     symbol: "exclamationmark.triangle")
            return
        }

        // ONLY a resolved-but-empty result (no selection, no folder window)
        // may fall back to the desktop. A script FAILURE must NOT silently
        // downgrade to the desktop: that is how every click landed there.
        var directory: String
        if !path.isEmpty {
            directory = path
        } else if !coldLaunch,
                  let desktop = FileManager.default.urls(for: .desktopDirectory,
                                                          in: .userDomainMask).first {
            // Running-app click with no Finder window → desktop (go2shell
            // parity). Skipped on cold launch: login also has Finder
            // frontmost.
            note("no Finder selection/window → desktop fallback")
            directory = desktop.path
        } else {
            note("skip: no Finder folder (cold=\(coldLaunch ? 1 : 0))")
            return
        }

        // A selected FILE opens its parent folder; a stale path is dropped.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else {
            note("skip: stale path \(directory)")
            return
        }
        if !isDirectory.boolValue {
            directory = (directory as NSString).deletingLastPathComponent
        }

        // Launch-by-double-click guard: opening this app from Finder must never
        // spawn a terminal. TWO shapes have to be covered, and the earlier
        // single container check missed the second one in the field
        // (log: "opening /Applications/JJType.app in iTerm" on a double click):
        //   • front window = the bundle's CONTAINER (/Applications) → the
        //     window-target branch of the script;
        //   • the bundle itself SELECTED in a window (any view mode) → the
        //     script returns the bundle path, and the file→parent fix-up above
        //     does NOT apply because a bundle IS a directory.
        // A broad /Applications-prefix block (go2shell's heuristic) would also
        // eat legitimate "open a terminal here" clicks while the user is
        // browsing /Applications, so the match stays exact.
        let bundlePath = Bundle.main.bundleURL
        let normalizedDirectory = Self.normalized(directory)
        if normalizedDirectory == Self.normalized(bundlePath.deletingLastPathComponent().path)
            || normalizedDirectory == Self.normalized(bundlePath.path) {
            note("skip: launch-by-double-click (\(normalizedDirectory))")
            return
        }

        openTerminal(at: URL(fileURLWithPath: directory, isDirectory: true))
    }

    /// `POSIX path of (alias)` returns folder paths WITH a trailing slash, so
    /// every comparison goes through standardizedFileURL (also collapses "..",
    /// "." and duplicate slashes). Symlinks are deliberately NOT resolved.
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Private
    /// Selection first, then the frontmost Finder window. Runs on the main
    /// thread (NSAppleScript is main-thread-affine).
    ///
    /// The per-block `try` is only there to tolerate "no selection"/"no
    /// window"; it must NOT swallow the permission error, otherwise a denied
    /// Automation grant silently produced "" → "no Finder window" → desktop
    /// fallback, which is exactly the bug that made every click land on the
    /// Desktop. Hence the explicit re-raise of -1743.
    private static func frontFinderPath() throws -> String {
        let source = """
        tell application "Finder"
            set out to ""
            try
                set theSelection to selection
                if (count of theSelection) > 0 then
                    set out to POSIX path of ((item 1 of theSelection) as alias)
                end if
            on error errMsg number errNum
                if errNum is -1743 then error number errNum
            end try
            if out is "" then
                try
                    if (count of windows) > 0 then
                        set w to front window
                        if (class of w is not desktop) then
                            set out to POSIX path of (target of w as alias)
                        end if
                    end if
                on error errMsg number errNum
                    if errNum is -1743 then error number errNum
                end try
            end if
            return out
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            throw SystemCommandError(reason: "AppleScript unavailable")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "nil"
            note("Finder script error \(number): \(message)")
            throw SystemCommandError(reason: "Finder: \(number) \(message)",
                                     isAuthorizationFailure: number == -1743)
        }
        return (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Opening the folder WITH the terminal app is plain LaunchServices — no
    /// terminal automation permission needed (same behaviour as go2shell's
    /// `open -a <terminal> <path>` route).
    private static func openTerminal(at folder: URL) {
        let terminal = TerminalApp.resolved
        guard let appURL = terminal.appURL ?? TerminalApp.terminal.appURL else {
            note("skip: no terminal app found")
            return
        }
        note("opening \(folder.path) in \(terminal.rawValue)")
        Task {
            do {
                try await NSWorkspace.shared.open([folder], withApplicationAt: appURL,
                                                  configuration: NSWorkspace.OpenConfiguration())
                note("terminal launch requested OK")
            } catch {
                note("terminal launch failed: \(error.localizedDescription)")
                CaptureToast.shared.show("无法启动终端", symbol: "exclamationmark.triangle")
            }
        }
    }
}
