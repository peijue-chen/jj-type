//
//  FinderTerminal.swift
//  jj-type
//
//  "Open terminal here" from the Finder toolbar (go2shell-style): the user
//  ⌘-drags JJType.app into the Finder toolbar; clicking the icon resolves the
//  current folder (selection → front window → desktop) and opens the preferred
//  terminal there. A click on the RUNNING resident app arrives as
//  `applicationShouldHandleReopen`; a click while it is not running cold
//  launches it (handled at the tail of `applicationDidFinishLaunching`, with
//  NO desktop fallback — at login Finder is frontmost with no windows and
//  that must never spawn a terminal). NOTE: the click ACTIVATES this
//  LSUIElement app, so `frontmostApplication` at handler time is usually the
//  app ITSELF, not Finder — the toolbar gate accepts either (see handleLaunch).
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

    /// Entry point from AppDelegate (reopen while running, launch when not).
    /// NSLog diagnostics at every early-exit: this flow is driven by GUI events
    /// (toolbar click) with no other feedback, so a silent no-op is undebuggable.
    static func handleLaunch(coldLaunch: Bool) {
        let now = Date()
        if let last = lastHandled, now.timeIntervalSince(last) < 0.5 { return }
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
        guard frontmost == finder || frontmost == own else {
            NSLog("[FinderTerminal] skip: frontmost=%@ (need Finder or self)", frontmost)
            return
        }

        let path: String?
        do {
            path = try frontFinderPath()
        } catch {
            // -1743: no Automation grant for Finder — the shared guide window
            // (system-settings deep link + per-target verification) explains it.
            NSLog("[FinderTerminal] skip: Finder automation denied (-1743), showing guide")
            AutomationGuideWindowController.shared.showIfNeeded(force: true)
            return
        }

        var directory = path ?? ""
        if directory.isEmpty, !coldLaunch,
           let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            // Running-app click with no Finder window → desktop (go2shell
            // parity). Skipped on cold launch: login also has Finder frontmost.
            directory = desktop.path
        }
        guard !directory.isEmpty else {
            NSLog("[FinderTerminal] skip: no resolvable folder (cold=%@)", coldLaunch ? "1" : "0")
            return
        }

        // A selected FILE opens its parent folder; a stale path is dropped.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else {
            NSLog("[FinderTerminal] skip: stale path %@", directory)
            return
        }
        if !isDirectory.boolValue {
            directory = (directory as NSString).deletingLastPathComponent
        }

        // Launch-by-double-click guard: double-clicking this app always has the
        // bundle's own folder as the front Finder window — or the bundle itself
        // selected (column view), which resolves to the same folder — so one
        // EXACT match suffices. A broad /Applications-prefix block (go2shell's
        // heuristic) would also eat legitimate "open a terminal here" clicks
        // while the user is browsing /Applications.
        let appContainer = Bundle.main.bundleURL.deletingLastPathComponent().path
        if directory == appContainer {
            NSLog("[FinderTerminal] skip: launch-by-double-click container %@", directory)
            return
        }

        openTerminal(at: URL(fileURLWithPath: directory, isDirectory: true))
    }

    // MARK: - Private
    /// Selection first, then the frontmost Finder window. Runs on the main
    /// thread (NSAppleScript is main-thread-affine); a missing Automation
    /// grant surfaces as -1743.
    private static func frontFinderPath() throws -> String? {
        let source = """
        tell application "Finder"
            try
                set theSelection to selection
                if (count of theSelection) > 0 then
                    return POSIX path of ((item 1 of theSelection) as alias)
                end if
            end try
            try
                return POSIX path of (target of front window as alias)
            on error
                return ""
            end try
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == -1743 { // errAEEventNotPermitted
                throw SystemCommandError(reason: "Finder", isAuthorizationFailure: true)
            }
            return nil // Any other Finder hiccup: silently do nothing.
        }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Opening the folder WITH the terminal app is plain LaunchServices — no
    /// terminal automation permission needed (same behaviour as go2shell's
    /// `open -a <terminal> <path>` route).
    private static func openTerminal(at folder: URL) {
        let terminal = TerminalApp.resolved
        NSLog("[FinderTerminal] opening %@ in %@", folder.path, terminal.rawValue)
        guard let appURL = terminal.appURL ?? TerminalApp.terminal.appURL else {
            NSLog("[FinderTerminal] skip: no terminal app found")
            return
        }
        Task {
            _ = try? await NSWorkspace.shared.open([folder], withApplicationAt: appURL,
                                                   configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
