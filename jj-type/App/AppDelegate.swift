//
//  AppDelegate.swift
//  jj-type
//
//  Menu-bar app lifecycle: status item, hotkeys, capture → AI → result pipeline.
//

import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        let store = SettingsStore()
        settingsStore = store
        hotkeyManager = HotkeyManager()
        super.init()
    }

    private var statusItem: NSStatusItem?

    private let settingsStore: SettingsStore
    private let hotkeyManager: HotkeyManager
    private let textCapture = TextCaptureService()
    private let aiClient = AIClient()
    private let captureOverlay = CaptureOverlayController()
    private let keepAwake = KeepAwakeService()
    private let inputSourceKeeper = InputSourceKeeper.shared
    private let netWatch = NetWatchService.shared

    private var resultPanel: ResultPanelController?
    private var translationWindow: TranslationWindowController?
    private var launcherWindow: LauncherWindowController?
    private var settingsWindow: SettingsWindowController?
    private var clipboardPanel: ClipboardHistoryPanelController?
    private var qrWindow: QRWindowController?
    private var devToolWindow: DevToolWindowController?
    private var inFlightTask: Task<Void, Never>?
    /// Source text of the last successful ⌥+E capture — the input for the
    /// result panel's AI quick actions.
    private var lastCapturedSourceText: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FinderTerminal.note("didFinishLaunching frontmost="
            + (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"))
        resultPanel = ResultPanelController()
        resultPanel?.onQuickAction = { [weak self] action in
            self?.runQuickAction(action)
        }
        resultPanel?.onGenerateQR = { [weak self] in
            self?.generateQRFromSelection()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusIcon()

        rebuildStatusMenu()

        // Register global hotkeys IMMEDIATELY after the status item — a fresh
        // install (or a moved app) runs slower first-launch steps later in
        // this method (permission prompts, guides, index load, Finder probe),
        // and deferring registration made every shortcut feel dead until they
        // finished. The dispatch callbacks attach a few lines below; a hotkey
        // pressed in that millisecond window is simply a no-op.
        reregisterHotkeys()

        settingsStore.onProvidersChanged = { [weak self] in
            MainActor.assumeIsolated { self?.rebuildStatusMenu() }
        }
        settingsStore.onHotkeyChanged = { [weak self] in
            MainActor.assumeIsolated {
                self?.reregisterHotkeys()
            }
        }
        // Launch items carry their own hotkey AND feed the status menu, so one
        // callback drives both.
        settingsStore.onLaunchItemsChanged = { [weak self] in
            MainActor.assumeIsolated {
                self?.reregisterHotkeys()
            }
        }
        // Keep-awake: one callback drives both the menu section and the status
        // icon (active state swaps the symbol; timed state counts down).
        keepAwake.onChanged = { [weak self] in
            self?.refreshKeepAwakeUI()
        }
        // Network watchdog: starts itself when the saved config is enabled.
        netWatch.onStatusChanged = { [weak self] in
            MainActor.assumeIsolated { self?.rebuildStatusMenu() }
        }
        netWatch.configure(store: settingsStore)
        // Clipboard recording runs for the whole session; the panel reads the
        // current entries each time it opens.
        ClipboardHistoryService.shared.start()

        // Input-source keeper: restores the saved preference and starts the
        // observers. It stays inert unless the target input source is actually
        // installed AND enabled — refreshStatus() decides that.
        inputSourceKeeper.onChanged = { [weak self] in
            MainActor.assumeIsolated { self?.rebuildStatusMenu() }
        }
        inputSourceKeeper.setTarget(settingsStore.inputSourceKeeperTarget)
        inputSourceKeeper.setMode(settingsStore.inputSourceKeeperMode)
        if settingsStore.inputSourceKeeperEnabled {
            inputSourceKeeper.setEnabled(true)
        } else {
            inputSourceKeeper.refreshStatus()
        }
        // Re-scan when the app is activated: the user may have just installed
        // or enabled the target IME in System Settings. A status change fires
        // onChanged, which rebuilds the menu.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.inputSourceKeeper.refreshStatus()
            }
        }

        // PopClip-style selection bar (utils-7): appears on drag-selection.
        let selectionBar = SelectionActionBarController.shared
        selectionBar.actionsProvider = { [weak self] in
            self?.settingsStore.aiActions ?? []
        }
        selectionBar.onQuickAction = { [weak self] action, text in
            self?.lastCapturedSourceText = text
            self?.runQuickAction(action)
        }
        selectionBar.onGenerateQR = { [weak self] text in
            self?.generateAndPinQR(text)
        }
        if settingsStore.selectionBarEnabled {
            // The bar itself needs no grant (global MOUSE monitors are free),
            // but reading the selection via AX does — surface the reason
            // instead of failing silently when the grant is missing.
            selectionBar.setEnabled(true)
            if !AccessibilityPermission.isGranted {
                requestAccessibilityIfNeeded()
            }
        }

        hotkeyManager.onTranslate = { [weak self] in
            MainActor.assumeIsolated { self?.runTranslationWindowFlow() }
        }
        hotkeyManager.onCorrectAndTranslate = { [weak self] in
            MainActor.assumeIsolated { self?.runPipeline(mode: .correctAndTranslate) }
        }
        hotkeyManager.onCapture = { [weak self] in
            MainActor.assumeIsolated { self?.runCaptureFlow() }
        }
        hotkeyManager.onLauncher = { [weak self] in
            MainActor.assumeIsolated { self?.toggleLauncher() }
        }
        hotkeyManager.onClipboardHistory = { [weak self] in
            MainActor.assumeIsolated { self?.toggleClipboardHistory() }
        }
        hotkeyManager.onColorPicker = { [weak self] in
            MainActor.assumeIsolated { self?.runColorPickerFlow() }
        }
        hotkeyManager.onQRCode = { [weak self] in
            MainActor.assumeIsolated { self?.toggleQRWindow() }
        }
        hotkeyManager.onDevTool = { [weak self] in
            MainActor.assumeIsolated { self?.toggleDevToolWindow() }
        }
        hotkeyManager.onSelectionBar = { [weak self] in
            MainActor.assumeIsolated { self?.runSelectionBarFlow() }
        }
        hotkeyManager.onLaunchItem = { [weak self] slot in
            MainActor.assumeIsolated { self?.openLaunchItem(slot: slot) }
        }

        captureOverlay.onFinish = { [weak self] image, copied in
            self?.saveCapturedImage(image, alsoCopied: copied)
        }

        // Pinned images save through their right-click menu, to the same place.
        let store = settingsStore
        PinWindowController.saveSettings = {
            (directory: store.captureSaveDirectory, format: store.captureFormat)
        }

        // LSUIElement apps get no main menu — install one with a standard Edit menu
        // so ⌘V/⌘C/⌘X/⌘A/⌘Z work in text fields (B2 fix; the menu itself stays invisible).
        installMainMenu()

        // Finder toolbar clicks on the running app arrive as a reopen event.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication))

        if !AccessibilityPermission.isGranted && !settingsStore.accessibilityGuidedShown {
            settingsStore.accessibilityGuidedShown = true
            requestAccessibilityIfNeeded()
        }

        // Cold launch via a Finder toolbar click (app was not running): same
        // detection, no desktop fallback — at login Finder is frontmost with
        // no open windows and that must never spawn a terminal.
        FinderTerminal.handleLaunch(coldLaunch: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Finder toolbar click on the RUNNING app: LaunchServices sends a reopen
    /// (rapp) event; the LSUIElement app never activates, so Finder stays
    /// frontmost and FinderTerminal can detect the toolbar context. ⌥-click
    /// opens settings instead (go2shell parity).
    func applicationShouldHandleReopen(_ application: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        FinderTerminal.note("reopen (delegate) received visible=\(flag ? 1 : 0)")
        handleReopen()
        return true
    }

    /// A raw `kAEReopenApplication` handler is installed as well: for an
    /// LSUIElement app with no windows the delegate callback has been
    /// observed not to arrive at all, and the click then silently does
    /// nothing. AppKit's own handler stays in place, so the event can be
    /// delivered twice — FinderTerminal's 0.5 s debounce collapses that.
    @objc private func handleReopenEvent(_ event: NSAppleEventDescriptor,
                                         withReply reply: NSAppleEventDescriptor) {
        FinderTerminal.note("reopen (raw AE) received")
        handleReopen()
    }

    private func handleReopen() {
        if NSEvent.modifierFlags.contains(.option) {
            openSettings()
            settingsWindow?.selectTerminalSection()
        } else {
            FinderTerminal.handleLaunch(coldLaunch: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any half-typed settings field before the process goes away; a
        // text field only reports back on Return / focus loss.
        settingsWindow?.commitPendingEdits()
        // Carbon hotkeys are released with the process; nothing to clean up manually.
        // caffeinate children are NOT killed with their parent — stop them here.
        keepAwake.shutdown()
        // Stop the watchdog timer so no probe fires during teardown.
        netWatch.stop()
        // Never let a voice outlive the app.
        SpeechService.shared.stop()
    }

    // MARK: - Main menu (Edit shortcuts for text fields)

    /// Builds an invisible main menu whose Edit submenu provides the standard
    /// text-editing key equivalents through the responder chain.
    private func installMainMenu() {
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status menu

    /// Brand "JJ▮" template image (adapts to light/dark menu bar) with a
    /// bulletproof text fallback: nil image OR zero-size → visible "文A" title.
    private func configureStatusIcon() {
        guard let button = statusItem?.button else { return }
        // While keep-awake is on, the icon swaps to a coffee cup — a
        // glance-level "this Mac will not sleep" indicator that needs no menu.
        let symbol: NSImage?
        if keepAwake.isActive {
            symbol = NSImage(systemSymbolName: "cup.and.saucer.fill",
                             accessibilityDescription: "JJType 防休眠")
                ?? NSImage(systemSymbolName: "cup.and.saucer",
                           accessibilityDescription: "JJType 防休眠")
            symbol?.isTemplate = true
        } else {
            symbol = Theme.menuBarImage()
        }
        if let symbol, symbol.size.width > 0, symbol.size.height > 0 {
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
            button.image = symbol
        } else {
            button.image = nil
            button.title = "文A"
        }
        button.toolTip = "JJType"
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        if settingsStore.providers.isEmpty {
            let item = NSMenuItem(title: "尚未配置 AI 服务", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for provider in settingsStore.providers {
                let item = NSMenuItem(title: provider.name, action: #selector(selectProvider(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = provider.id
                item.state = provider.id == settingsStore.activeProviderId ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "启动器  \(settingsStore.launcherHotkey.displayText)",
                     action: #selector(openLauncherMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "截图  \(settingsStore.captureHotkey.displayText)",
                     action: #selector(startCapture), keyEquivalent: "").target = self
        menu.addItem(withTitle: "取色  \(settingsStore.colorPickerHotkey.displayText)",
                     action: #selector(openColorPicker), keyEquivalent: "").target = self
        menu.addItem(withTitle: "剪贴板历史  \(settingsStore.clipboardHotkey.displayText)",
                     action: #selector(openClipboardHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "二维码  \(settingsStore.qrCodeHotkey.displayText)",
                     action: #selector(openQRWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "开发工具  \(settingsStore.devToolHotkey.displayText)",
                     action: #selector(openDevToolWindow), keyEquivalent: "").target = self
        menu.addItem(keepAwakeMenuItem())
        menu.addItem(inputSourceMenuItem())
        menu.addItem(netWatchMenuItem())

        if !settingsStore.launchItems.isEmpty {
            let parent = NSMenuItem(title: "快捷启动", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for item in settingsStore.launchItems {
                let title = item.hotkey.map { "\(item.name)  \($0.displayText)" } ?? item.name
                let entry = NSMenuItem(title: title, action: #selector(openLaunchItemMenu(_:)),
                                       keyEquivalent: "")
                entry.target = self
                entry.representedObject = item.id
                if let icon = item.icon {
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                }
                submenu.addItem(entry)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "辅助功能权限引导", action: #selector(openAccessibilityGuide),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "屏幕录制权限引导", action: #selector(openScreenCaptureGuide),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "自动化权限引导", action: #selector(openAutomationGuide),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 jj-type", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        settingsStore.setActiveProvider(id: id)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: settingsStore)
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAccessibilityGuide() {
        AccessibilityGuideWindowController.shared.showIfNeeded(force: true)
    }

    @objc private func openScreenCaptureGuide() {
        ScreenCaptureGuideWindowController.shared.showIfNeeded(force: true)
    }

    @objc private func openAutomationGuide() {
        AutomationGuideWindowController.shared.showIfNeeded(force: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Mainstream permission flow: native system prompt first, guide window on top.
    private func requestAccessibilityIfNeeded() {
        // Primary: AXIsProcessTrustedWithOptions prompt (system dialog with a
        // direct "Open System Settings" button). Supplementary: our Chinese guide.
        if !AccessibilityPermission.requestTrust() {
            AccessibilityGuideWindowController.shared.showIfNeeded(force: true)
        }
    }

    // MARK: - Keep awake

    /// Keep-awake state changed (or the minute tick fired): the menu section
    /// and the status icon both reflect the current state.
    private func refreshKeepAwakeUI() {
        configureStatusIcon()
        rebuildStatusMenu()
    }

    /// 「防休眠」submenu: indefinite toggle, three timed presets (checkmark on
    /// the running mode), and an explicit stop entry. The parent title counts
    /// down while a timed session is active.
    private func keepAwakeMenuItem() -> NSMenuItem {
        let title: String
        if keepAwake.isActive {
            if keepAwake.sessionDuration == nil {
                title = "防休眠 · 已开启"
            } else if let minutes = keepAwake.remainingMinutes {
                title = "防休眠 · 剩余 \(minutes) 分钟"
            } else {
                title = "防休眠 · 已开启"
            }
        } else {
            title = "防休眠"
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let presets: [(String, TimeInterval?)] = [
            ("开启（直到手动关闭）", nil),
            ("30 分钟", 30 * 60),
            ("1 小时", 60 * 60),
            ("2 小时", 2 * 60 * 60),
        ]
        for (presetTitle, seconds) in presets {
            let item = NSMenuItem(title: presetTitle, action: #selector(startKeepAwake(_:)),
                                  keyEquivalent: "")
            item.target = self
            // nil representedObject = the indefinite preset.
            if let seconds {
                item.representedObject = seconds
            }
            item.state = (keepAwake.isActive && keepAwake.sessionDuration == seconds) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let stop = NSMenuItem(title: "关闭防休眠", action: #selector(stopKeepAwake),
                              keyEquivalent: "")
        stop.target = self
        stop.isEnabled = keepAwake.isActive
        submenu.addItem(stop)
        parent.submenu = submenu
        return parent
    }

    /// Menu action: (re)starts keep-awake with the chosen preset. A start
    /// failure must never be silent (feedback rule) — it surfaces as an alert.
    @objc private func startKeepAwake(_ sender: NSMenuItem) {
        let duration = sender.representedObject as? TimeInterval
        do {
            try keepAwake.enable(for: duration)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法开启防休眠"
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func stopKeepAwake() {
        keepAwake.disable()
    }

    // MARK: - Network watchdog

    /// 「网络守护」submenu: enable toggle, live phase, manual check / switch and
    /// a shortcut to the settings page. Every action is also reachable by click
    /// so the watchdog is usable without remembering a hotkey.
    private func netWatchMenuItem() -> NSMenuItem {
        let config = netWatch.config
        let title = config.enabled ? "网络守护 · \(netWatch.phase.title)" : "网络守护"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let toggle = NSMenuItem(title: "启用网络守护", action: #selector(toggleNetWatch(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = config.enabled ? .on : .off
        submenu.addItem(toggle)

        submenu.addItem(.separator())

        let check = NSMenuItem(title: "立即检查", action: #selector(checkNetWatch), keyEquivalent: "")
        check.target = self
        check.isEnabled = config.enabled
        submenu.addItem(check)

        let switchNow = NSMenuItem(title: "立即切换备用网络", action: #selector(switchNetWatchNow), keyEquivalent: "")
        switchNow.target = self
        switchNow.isEnabled = config.enabled
        submenu.addItem(switchNow)

        submenu.addItem(.separator())

        let settings = NSMenuItem(title: "网络守护设置…", action: #selector(openNetWatchSettings), keyEquivalent: "")
        settings.target = self
        submenu.addItem(settings)

        parent.submenu = submenu
        return parent
    }

    @objc private func toggleNetWatch(_ sender: NSMenuItem) {
        var config = netWatch.config
        config.enabled.toggle()
        netWatch.updateConfig(config)
        rebuildStatusMenu()
    }

    @objc private func checkNetWatch() {
        netWatch.checkNow()
    }

    @objc private func switchNetWatchNow() {
        netWatch.switchNow()
    }

    @objc private func openNetWatchSettings() {
        openSettings()
        settingsWindow?.selectNetWatchSection()
    }

    // MARK: - Input source keeper

    /// 「输入法」submenu: enable toggle, target picker, correction mode, live
    /// status and a shortcut to the system keyboard pane. The keeper stays
    /// inert when the target input source is not installed — the submenu says
    /// so instead of offering a toggle that would do nothing.
    private func inputSourceMenuItem() -> NSMenuItem {
        let keeper = inputSourceKeeper
        let title: String
        if keeper.isEnabled, keeper.status.isReady {
            title = "输入法 · 保持\(keeper.targetDisplayName)"
        } else {
            title = "输入法"
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let toggle = NSMenuItem(title: "保持输入法", action: #selector(toggleInputSourceKeeper(_:)),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = keeper.isEnabled ? .on : .off
        // An enabled keeper stays toggleable so it can always be turned off,
        // even after the target IME has been uninstalled.
        toggle.isEnabled = keeper.status.isReady || keeper.isEnabled
        submenu.addItem(toggle)

        submenu.addItem(.separator())
        let targetItem = NSMenuItem(title: "目标输入法", action: nil, keyEquivalent: "")
        targetItem.submenu = inputSourceTargetSubmenu()
        submenu.addItem(targetItem)

        submenu.addItem(.separator())
        for mode in InputSourceKeeperMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setInputSourceKeeperMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = keeper.mode == mode ? .on : .off
            item.isEnabled = keeper.status.isReady
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let status = NSMenuItem(title: keeper.status.summary, action: nil, keyEquivalent: "")
        status.isEnabled = false
        submenu.addItem(status)
        if let current = keeper.currentSourceName {
            let currentItem = NSMenuItem(title: "当前：\(current)", action: nil, keyEquivalent: "")
            currentItem.isEnabled = false
            submenu.addItem(currentItem)
        }
        if !keeper.status.isReady {
            let open = NSMenuItem(title: "打开输入法设置…", action: #selector(openKeyboardSettings),
                                  keyEquivalent: "")
            open.target = self
            submenu.addItem(open)
        }

        parent.submenu = submenu
        return parent
    }

    /// Radio list of every enabled, selectable **input method** plus an "auto"
    /// entry that falls back to Sogou. Keyboard layouts are excluded so the
    /// user cannot accidentally pin ABC.
    private func inputSourceTargetSubmenu() -> NSMenu {
        let keeper = inputSourceKeeper
        let menu = NSMenu()

        let auto = NSMenuItem(title: "自动（搜狗）", action: #selector(setInputSourceKeeperTarget(_:)),
                              keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = keeper.targetID == nil ? .on : .off
        menu.addItem(auto)

        let sources = InputSourceKeeper.selectableInputMethods()
        if !sources.isEmpty {
            menu.addItem(.separator())
        }
        for source in sources {
            let item = NSMenuItem(title: source.name, action: #selector(setInputSourceKeeperTarget(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = source.id
            item.state = keeper.targetID == source.id ? .on : .off
            menu.addItem(item)
        }
        // Keep a stored target visible when it is not in the IME list: either a
        // keyboard layout picked before the list was filtered, or an IME that is
        // currently uninstalled/disabled.
        if let target = keeper.targetID,
           !sources.contains(where: { InputSourceKeeper.isSameSource($0.id, target) }) {
            let stillValid = InputSourceKeeper.selectableSources()
                .contains { InputSourceKeeper.isSameSource($0.id, target) }
            menu.addItem(.separator())
            let item = NSMenuItem(title: stillValid ? "\(target)（键盘布局）" : "\(target)（不可用）",
                                  action: #selector(setInputSourceKeeperTarget(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = target
            item.state = .on
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleInputSourceKeeper(_ sender: NSMenuItem) {
        let enabled = !inputSourceKeeper.isEnabled
        settingsStore.inputSourceKeeperEnabled = enabled
        inputSourceKeeper.setEnabled(enabled)
        rebuildStatusMenu()
    }

    @objc private func setInputSourceKeeperTarget(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String ?? ""
        let id: String? = raw.isEmpty ? nil : raw
        settingsStore.inputSourceKeeperTarget = id
        inputSourceKeeper.setTarget(id)
        rebuildStatusMenu()
    }

    @objc private func setInputSourceKeeperMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = InputSourceKeeperMode(rawValue: raw) else { return }
        settingsStore.inputSourceKeeperMode = mode
        inputSourceKeeper.setMode(mode)
        rebuildStatusMenu()
    }

    @objc private func openKeyboardSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Clipboard history

    /// Clipboard hotkey: toggles, so pressing it twice dismisses the panel.
    private func toggleClipboardHistory() {
        if let panel = clipboardPanel, panel.isVisible {
            panel.dismiss()
        } else {
            clipboardHistoryPanelIfNeeded().present(entries: ClipboardHistoryService.shared.entries)
        }
    }

    @objc private func openClipboardHistory() {
        clipboardHistoryPanelIfNeeded().present(entries: ClipboardHistoryService.shared.entries)
    }

    private func clipboardHistoryPanelIfNeeded() -> ClipboardHistoryPanelController {
        if let clipboardPanel { return clipboardPanel }
        let controller = ClipboardHistoryPanelController()
        clipboardPanel = controller
        return controller
    }

    // MARK: - Dev tool window (utils-8)

    /// ⌥J toggles the developer tool window (JSON / Base64 / URI).
    /// Close ONLY when the window is actually the focused one — if it is
    /// visible but buried behind other apps' windows, the hotkey must RAISE
    /// it (floating level + activate), not silently close it.
    private func toggleDevToolWindow() {
        if let devToolWindow, devToolWindow.window?.isVisible == true,
           NSApp.isActive, devToolWindow.window?.isKeyWindow == true {
            devToolWindow.closeAndRelease()
        } else {
            devToolWindowIfNeeded().present()
        }
    }

    @objc private func openDevToolWindow() {
        devToolWindowIfNeeded().present()
    }

    private func devToolWindowIfNeeded() -> DevToolWindowController {
        if let devToolWindow { return devToolWindow }
        let controller = DevToolWindowController()
        // A formatted JSON tree can be heavy — closing the window drops the
        // whole controller (window + texts + nodes) so nothing lingers.
        controller.onClosed = { [weak self] in
            self?.devToolWindow = nil
        }
        devToolWindow = controller
        return controller
    }

    // MARK: - QR window (utils-6)

    /// ⌥Q toggles the dedicated QR window (generate / decode).
    private func toggleQRWindow() {
        if let qrWindow, qrWindow.window?.isVisible == true {
            qrWindow.window?.orderOut(nil)
        } else {
            qrWindowIfNeeded().present()
        }
    }

    @objc private func openQRWindow() {
        qrWindowIfNeeded().present()
    }

    private func qrWindowIfNeeded() -> QRWindowController {
        if let qrWindow { return qrWindow }
        let controller = QRWindowController()
        qrWindow = controller
        return controller
    }

    // MARK: - Screen color picker

    /// Status-menu entry for the picker (the hotkey is not the only way in).
    @objc private func openColorPicker() {
        runColorPickerFlow()
    }

    /// ⌥P flow: the loupe samples pixels via CGDisplayCreateImage, which needs
    /// the same Screen Recording grant as the screenshot flow.
    private func runColorPickerFlow() {
        guard ScreenCapturePermission.isGranted else {
            ScreenCapturePermission.request()
            ScreenCaptureGuideWindowController.shared.showIfNeeded(force: true)
            return
        }
        EyedropperController.shared.begin()
    }

    // MARK: - Selection action bar (explicit invocation)

    /// ⌥S flow: the user asked for the chips, so this runs the FULL capture
    /// chain (AX + synthetic-⌘C fallback) at the pointer and shows the bar —
    /// the escape hatch when the automatic bar is switched off, and the only
    /// way to reach it in apps that expose no AX selected text.
    /// With 「快捷键直接翻译」 on, the same capture runs the built-in 翻译
    /// action straight away — no bar, no second click.
    private func runSelectionBarFlow() {
        guard AccessibilityPermission.isGranted else {
            requestAccessibilityIfNeeded()
            return
        }
        if settingsStore.selectionBarDirectTranslate {
            runDirectTranslateFlow()
            return
        }
        SelectionActionBarController.shared.showForCurrentSelection(at: NSEvent.mouseLocation)
    }

    /// ⌥S with 「快捷键直接翻译」: capture the selection and run the built-in
    /// 翻译 action immediately (same pipeline as the 翻译 chip — the result
    /// panel is the only UI). The pasteboard is kept: this is an explicit
    /// user command, exactly like the bar path.
    private func runDirectTranslateFlow() {
        SelectionActionBarController.shared.dismiss()
        guard let action = settingsStore.aiActions.first(where: {
            $0.id == QuickActionCatalog.translateActionID
        }) else { return }
        textCapture.captureSelectedText(clipboardPolicy: .keep) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                lastCapturedSourceText = text
                runQuickAction(action)
            case .failure(let error):
                CaptureToast.shared.show(error.localizedDescription, symbol: "text.cursor")
            }
        }
    }

    // MARK: - Pipeline

    /// ⌥+E flow: capture → floating result panel (unchanged behavior).
    private func runPipeline(mode: TranslateMode) {
        // Latest-wins: cancel any in-flight request before starting a new capture.
        inFlightTask?.cancel()
        inFlightTask = nil

        guard AccessibilityPermission.isGranted else {
            // Missing permission → native prompt + guide, NOT just a panel error.
            requestAccessibilityIfNeeded()
            return
        }
        guard let provider = settingsStore.activeProvider else {
            resultPanel?.showError("尚未选择当前使用的 AI 服务，请在菜单栏图标或设置… 中选择")
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        guard let panel = resultPanel else { return }
        // The floating selection bar must not hover over the result panel.
        SelectionActionBarController.shared.dismiss()
        // Fresh action chips on every show, so Settings edits apply live
        // (the persisted list includes the seeded built-ins).
        panel.quickActions = settingsStore.aiActions
        panel.showLoading(near: mouseLocation, mode: mode) { [weak self] in
            self?.inFlightTask?.cancel()
        }

        inFlightTask = Task { [aiClient, textCapture, panel] in
            let captured: Result<String, CaptureError> = await withCheckedContinuation { continuation in
                textCapture.captureSelectedText { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled else { return }

            switch captured {
            case .failure(let error):
                panel.showError(error.localizedDescription)
                return
            case .success(let text):
                lastCapturedSourceText = text
                // The panel's speaker reads the captured source and shows its
                // IPA when it is a single English word.
                panel.sourceText = text
                let task = LanguageRouter.makeTask(text: text)
                let systemPrompt = PromptBuilder.systemPrompt(mode: mode, language: task.language)
                let userPrompt = PromptBuilder.userPrompt(text: text, mode: mode)
                do {
                    guard let apiKey = KeychainStore.loadAPIKey(for: provider.id), !apiKey.isEmpty else {
                        panel.showError("该服务未配置 API Key，请在设置中填写")
                        return
                    }
                let reply = try await aiClient.complete(provider: provider, apiKey: apiKey,
                                                        systemPrompt: systemPrompt,
                                                        userPrompt: userPrompt)
                guard !Task.isCancelled else { return }
                guard let result = PromptBuilder.parse(reply) else {
                    panel.showError("AI 返回异常（未包含有效结果，可能被截断），请重试")
                    return
                }
                panel.showResult(result, replaceEnabled: AccessibilityPermission.isGranted)
                } catch {
                    guard !Task.isCancelled else { return }
                    let message = Self.errorMessage(for: error)
                    panel.showError(message)
                }
            }
        }
    }

    /// ⌥+D flow (It8): dedicated input window. Show it immediately (without
    /// stealing focus so the synthetic ⌘C still targets the original app),
    /// then pre-fill + translate on capture success, or focus the empty input
    /// for typing when nothing is selected.
    private func runTranslationWindowFlow() {
        inFlightTask?.cancel()
        inFlightTask = nil

        guard AccessibilityPermission.isGranted else {
            requestAccessibilityIfNeeded()
            return
        }

        if translationWindow == nil {
            translationWindow = makeTranslationWindow()
        }
        guard let window = translationWindow else { return }
        window.presentWithoutActivating()

        // Try to capture the current selection while the original app still has focus.
        textCapture.captureSelectedText { result in
            switch result {
            case .success(let text):
                window.prefillAndTranslate(text)
            case .failure:
                // No selection (or capture failed) → empty input, ready for typing.
                window.activateAndFocusInput()
            }
        }
    }

    private func makeTranslationWindow() -> TranslationWindowController {
        let window = TranslationWindowController()
        window.onTranslate = { [weak self] text in
            guard let self else { return }
            self.translateTypedText(text)
        }
        window.onGenerateQR = { [weak self] text in
            self?.generateAndPinQR(text)
        }
        return window
    }

    /// Translates text entered in the input window and renders below it.
    private func translateTypedText(_ text: String) {
        guard let window = translationWindow else { return }
        guard let provider = settingsStore.activeProvider else {
            window.showError("尚未选择当前使用的 AI 服务，请在菜单栏图标或设置… 中选择")
            return
        }
        inFlightTask?.cancel()
        inFlightTask = Task { [aiClient, window] in
            // Single-exit loading reset: every path (result, error, cancellation,
            // missing key) guarantees the spinner/status clear.
            defer { window.setLoading(false) }
            let task = LanguageRouter.makeTask(text: text)
            let systemPrompt = PromptBuilder.systemPrompt(mode: .translate, language: task.language)
            let userPrompt = PromptBuilder.userPrompt(text: text, mode: .translate)
            do {
                guard let apiKey = KeychainStore.loadAPIKey(for: provider.id), !apiKey.isEmpty else {
                    window.showError("该服务未配置 API Key，请在设置中填写")
                    return
                }
                let reply = try await aiClient.complete(provider: provider, apiKey: apiKey,
                                                        systemPrompt: systemPrompt,
                                                        userPrompt: userPrompt)
                guard !Task.isCancelled else { return }
                guard let result = PromptBuilder.parse(reply) else {
                    window.showError("AI 返回异常（未包含有效结果，可能被截断），请重试")
                    return
                }
                let text = (result.translation.isEmpty ? result.corrected : result.translation)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Blank result (e.g. reasoning model truncated into empty fields)
                // must surface an error, never a silently blank result area.
                if text.isEmpty {
                    window.showError("AI 返回为空（可能被截断），请重试或更换模型")
                } else {
                    // The spelling fix is display-only — the translation already
                    // used the repaired text. Pass it only when a real
                    // translation came back; otherwise it IS the result.
                    window.showResult(text, corrected: result.translation.isEmpty ? "" : result.corrected)
                }
            } catch {
                guard !Task.isCancelled else { return }
                window.showError(Self.errorMessage(for: error))
            }
        }
    }

    // MARK: - AI quick actions

    /// System prompt for quick actions: plain-text output, no JSON contract.
    private static let quickActionSystemPrompt = """
    You are a desktop text assistant. Follow the user's instruction exactly and \
    output ONLY the resulting text — no explanations, no markdown fences, no JSON, \
    no thinking.
    """

    /// Runs a quick action (翻译 / 纠正 / 润色 / 改写 / custom) against the
    /// text of the last capture and renders the reply in the same result panel.
    private func runQuickAction(_ action: QuickAction) {
        guard let source = lastCapturedSourceText, !source.isEmpty,
              let panel = resultPanel else { return }
        // Selection-bar path: the bar dismisses itself, but the ⌥E-panel chip
        // path leaves it hanging over the result — close it here too, and
        // refresh the chips so a Settings edit is reflected immediately.
        SelectionActionBarController.shared.dismiss()
        panel.quickActions = settingsStore.aiActions
        panel.sourceText = source
        guard let provider = settingsStore.activeProvider else {
            panel.showError("尚未选择当前使用的 AI 服务，请在菜单栏图标或设置… 中选择")
            return
        }

        // The built-in 翻译 runs the EXACT pipeline of the ⌥D translation
        // window (LanguageRouter → PromptBuilder → {"corrected","translation"}
        // parse): identical prompt, JSON contract, reasoning-model recovery and
        // truncation retry. The template pipeline could not match it on long
        // selections (forced JSON mode on a plain-text instruction).
        if action.id == QuickActionCatalog.translateActionID {
            inFlightTask?.cancel()
            panel.showQuickLoading(actionName: action.name)
            DiagnosticLog.note("quick[\(action.name)] start len=\(source.count) provider=\(provider.model)")
            inFlightTask = Task { [aiClient, panel] in
                do {
                    guard let apiKey = KeychainStore.loadAPIKey(for: provider.id), !apiKey.isEmpty else {
                        DiagnosticLog.note("quick[\(action.name)] missing API key")
                        panel.showError("该服务未配置 API Key，请在设置中填写")
                        return
                    }
                    let task = LanguageRouter.makeTask(text: source)
                    let systemPrompt = PromptBuilder.systemPrompt(mode: .translate,
                                                                  language: task.language)
                    let userPrompt = PromptBuilder.userPrompt(text: source, mode: .translate)
                    var reply = try await aiClient.complete(provider: provider, apiKey: apiKey,
                                                            systemPrompt: systemPrompt,
                                                            userPrompt: userPrompt)
                    if Task.isCancelled { return }
                    // Reasoning models occasionally emit a literal "{}" (seen in
                    // ai.log: content=2, answer rehearsed only in reasoning) —
                    // one automatic retry beats making the user click again.
                    if PromptBuilder.parse(reply) == nil {
                        DiagnosticLog.note("quick[\(action.name)] parse failed (\(reply.prefix(40))) — retrying once")
                        reply = try await aiClient.complete(provider: provider, apiKey: apiKey,
                                                            systemPrompt: systemPrompt,
                                                            userPrompt: userPrompt)
                    }
                    guard !Task.isCancelled else {
                        DiagnosticLog.note("quick[\(action.name)] cancelled after complete")
                        return
                    }
                    DiagnosticLog.note("quick[\(action.name)] reply \(reply.count) chars: \(reply.prefix(80))")
                    guard let result = PromptBuilder.parse(reply) else {
                        DiagnosticLog.note("quick[\(action.name)] parse failed after retry")
                        panel.showError("AI 返回异常（未包含有效结果，可能被截断），请重试")
                        return
                    }
                    let translated = (result.translation.isEmpty
                                      ? result.corrected : result.translation)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if translated.isEmpty {
                        DiagnosticLog.note("quick[\(action.name)] empty translation")
                        panel.showError("AI 返回为空（可能被截断），请重试或更换模型")
                    } else {
                        DiagnosticLog.note("quick[\(action.name)] showing result \(translated.count) chars")
                        panel.showQuickResult(title: action.name, text: translated,
                                              replaceEnabled: AccessibilityPermission.isGranted)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    DiagnosticLog.note("quick[\(action.name)] error: \(error.localizedDescription)")
                    panel.showError(Self.errorMessage(for: error))
                }
            }
            return
        }

        // Plain-text actions (纠正 / 润色 / 改写 / custom): NO forced JSON mode —
        // the answer is plain text, and json_object made long replies come back
        // as truncated / multi-key JSON the extractor could not recover.
        inFlightTask?.cancel()
        panel.showQuickLoading(actionName: action.name)
        DiagnosticLog.note("quick[\(action.name)] start len=\(source.count) provider=\(provider.model)")
        inFlightTask = Task { [aiClient, panel] in
            do {
                guard let apiKey = KeychainStore.loadAPIKey(for: provider.id), !apiKey.isEmpty else {
                    DiagnosticLog.note("quick[\(action.name)] missing API key")
                    panel.showError("该服务未配置 API Key，请在设置中填写")
                    return
                }
                let reply = try await aiClient.complete(provider: provider, apiKey: apiKey,
                                                        systemPrompt: Self.quickActionSystemPrompt,
                                                        userPrompt: action.resolvedPrompt(for: source),
                                                        jsonMode: false)
                guard !Task.isCancelled else {
                    DiagnosticLog.note("quick[\(action.name)] cancelled after complete")
                    return
                }
                DiagnosticLog.note("quick[\(action.name)] reply \(reply.count) chars: \(reply.prefix(80))")
                // JSON-wrapped replies from weak models are unwrapped here.
                let cleaned = PromptBuilder.extractPlainText(reply)
                if cleaned.isEmpty {
                    DiagnosticLog.note("quick[\(action.name)] empty after extract")
                    panel.showError("AI 返回为空（可能被截断），请重试或更换模型")
                } else {
                    DiagnosticLog.note("quick[\(action.name)] showing result \(cleaned.count) chars")
                    panel.showQuickResult(title: action.name, text: cleaned,
                                          replaceEnabled: AccessibilityPermission.isGranted)
                }
            } catch {
                guard !Task.isCancelled else { return }
                DiagnosticLog.note("quick[\(action.name)] error: \(error.localizedDescription)")
                panel.showError(Self.errorMessage(for: error))
            }
        }
    }

    // MARK: - QR generation

    /// Generates a QR for `text` and pins it as a floating image (drag to
    /// move; right-click to copy / save — same affordances as pinned shots).
    private func generateAndPinQR(_ text: String) {
        do {
            let image = try QRService.generateQR(for: text)
            let pointSize = CGSize(width: 240, height: 240)
            // Centered on the screen the pointer is on.
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            let origin = CGPoint(x: visible.midX - pointSize.width / 2,
                                 y: visible.midY - pointSize.height / 2)
            PinWindowController.show(image: image, pointSize: pointSize, at: origin)
            CaptureToast.shared.show("二维码已生成 · 拖动移动，右键可复制 / 保存",
                                     symbol: "qrcode", duration: 2.5)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "生成二维码失败"
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.runModal()
        }
    }

    /// Result panel's QR chip: code for the last captured selection.
    private func generateQRFromSelection() {
        guard let text = lastCapturedSourceText, !text.isEmpty else { return }
        generateAndPinQR(text)
    }

    /// Uniform Chinese error message for pipeline failures.
    private static func errorMessage(for error: Error) -> String {
        (error as? AIError)?.errorDescription
            ?? (error as? LocalizedError)?.errorDescription
            ?? "请求失败：\(error.localizedDescription)"
    }

    // MARK: - Screenshot

    /// ⌘⇧2 flow: permission gate → freeze screens → selection overlay.
    private func runCaptureFlow() {
        guard ScreenCapturePermission.isGranted else {
            ScreenCapturePermission.request()
            ScreenCaptureGuideWindowController.shared.showIfNeeded(force: true)
            return
        }
        Task { await captureOverlay.begin() }
    }

    @objc private func startCapture() {
        runCaptureFlow()
    }

    /// The overlay already closed; only the disk write is left. `alsoCopied` is
    /// true for the double-click path (the image is already on the pasteboard),
    /// so a single toast can report both outcomes.
    private func saveCapturedImage(_ image: CGImage, alsoCopied: Bool) {
        let directory = settingsStore.captureSaveDirectory
        let format = settingsStore.captureFormat
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { [image] in
                    try CaptureExporter.save(image, to: directory, format: format)
                }.value
                CaptureToast.shared.show(alsoCopied
                                         ? "已复制并保存 · \(url.lastPathComponent)"
                                         : "已保存 · \(url.lastPathComponent)",
                                         symbol: alsoCopied ? "doc.on.doc"
                                                            : "square.and.arrow.down")
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = alsoCopied ? "已复制，但保存截图失败" : "保存截图失败"
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                alert.informativeText = alsoCopied
                    ? "图片已在剪贴板，写入文件时出错：\(reason)"
                    : reason
                alert.runModal()
            }
        }
    }

    // MARK: - Launch items

    /// Launcher hotkey: toggles, so pressing it twice is a no-op instead of
    /// stacking a second panel on top of the first.
    private func toggleLauncher() {
        let window = launcherWindowIfNeeded()
        if window.isVisible {
            window.dismiss()
        } else {
            window.present(items: settingsStore.launchItems)
        }
    }

    private func launcherWindowIfNeeded() -> LauncherWindowController {
        if let launcherWindow { return launcherWindow }
        let controller = LauncherWindowController()
        controller.onOpenItem = { [weak self] item in self?.perform(item) }
        controller.onOpenApp = { [weak self] url in self?.openApplication(at: url) }
        controller.onOpenDirect = { [weak self] raw in self?.openDirect(raw) }
        controller.onOpenSystem = { [weak self] command in self?.performSystemCommand(command) }
        launcherWindow = controller
        return controller
    }

    @objc private func openLauncherMenu() {
        launcherWindowIfNeeded().present(items: settingsStore.launchItems)
    }

    /// App found by the launcher's index (not configured as a launch item).
    private func openApplication(at url: URL) {
        guard NSWorkspace.shared.open(url) else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法打开「\(url.deletingPathExtension().lastPathComponent)」"
            alert.informativeText = "系统拒绝了这次操作，可能应用已被移除。"
            alert.runModal()
            return
        }
    }

    /// Alfred's "just open what I typed": an absolute / `~` path or a URL.
    /// Anything else that still looks like a domain gets https:// prefixed.
    private func openDirect(_ raw: String) {
        let expanded = (raw as NSString).expandingTildeInPath
        let url: URL?
        if expanded.hasPrefix("/") {
            url = FileManager.default.fileExists(atPath: expanded)
                ? URL(fileURLWithPath: expanded) : nil
        } else if let parsed = URL(string: raw), parsed.scheme != nil {
            url = parsed
        } else if expanded.contains(".") {
            url = URL(string: "https://\(expanded)")
        } else {
            url = nil
        }
        guard let url, NSWorkspace.shared.open(url) else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法打开「\(raw)」"
            alert.informativeText = "既不是存在的文件路径，也不是有效的网址。"
            alert.runModal()
            return
        }
    }

    /// Alfred-style system rows from the launcher. Destructive commands confirm
    /// first; failures always surface as an alert (feedback rule).
    private func performSystemCommand(_ command: SystemCommand) {
        if command.requiresConfirmation {
            // The launcher never activates the app, so without this the modal
            // would come up behind the user's frontmost window and ⏎ would not
            // reach it.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "确定要「\(command.title)」吗？"
            alert.informativeText = command.confirmationHint
            alert.alertStyle = .warning
            alert.addButton(withTitle: command.title)
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try command.perform()
            // Empty trash is the only one whose success is not self-evident
            // (lock/sleep/restart take over the screen); confirm it with a toast.
            if command == .emptyTrash {
                CaptureToast.shared.show("已清空废纸篓", symbol: "trash")
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法执行「\(command.title)」"
            if let systemError = error as? SystemCommandError, systemError.isAuthorizationFailure {
                alert.informativeText = "请到 系统设置 → 隐私与安全性 → 自动化，" +
                    "勾选允许 JJType 控制 \(systemError.reason)，然后重试。"
                alert.addButton(withTitle: "打开设置")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                alert.informativeText = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Hotkey path: the slot is the identity, the item is looked up fresh so
    /// edits take effect without re-registering anything.
    private func openLaunchItem(slot: UInt32) {
        guard let item = settingsStore.launchItems.first(where: { $0.hotkeySlot == slot }) else {
            return
        }
        perform(item)
    }

    @objc private func openLaunchItemMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let item = settingsStore.launchItems.first(where: { $0.id == id }) else { return }
        perform(item)
    }

    /// Feedback rule: a launcher that does nothing is a bug, so a failure always
    /// surfaces (the success path is the app/window that appears).
    private func perform(_ item: LaunchItem) {
        do {
            try item.open()
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法打开「\(item.name)」"
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Hotkey changes

    /// Re-registers the built-in actions plus every launch item, with REAL
    /// conflict detection via reregister()'s result. Triggered at launch (W1)
    /// and whenever SettingsStore persists a binding (C1).
    private func reregisterHotkeys() {
        var bindings: [UInt32: Hotkey] = [
            HotkeyManager.HotkeyID.translate.rawValue: settingsStore.translateHotkey,
            HotkeyManager.HotkeyID.correctAndTranslate.rawValue: settingsStore.correctHotkey,
            HotkeyManager.HotkeyID.capture.rawValue: settingsStore.captureHotkey,
            HotkeyManager.HotkeyID.launcher.rawValue: settingsStore.launcherHotkey,
            HotkeyManager.HotkeyID.clipboardHistory.rawValue: settingsStore.clipboardHotkey,
            HotkeyManager.HotkeyID.colorPicker.rawValue: settingsStore.colorPickerHotkey,
            HotkeyManager.HotkeyID.qrCode.rawValue: settingsStore.qrCodeHotkey,
            HotkeyManager.HotkeyID.devTool.rawValue: settingsStore.devToolHotkey,
            HotkeyManager.HotkeyID.selectionBar.rawValue: settingsStore.selectionBarHotkey,
        ]
        var names: [UInt32: String] = [
            HotkeyManager.HotkeyID.translate.rawValue: "翻译",
            HotkeyManager.HotkeyID.correctAndTranslate.rawValue: "纠正+翻译",
            HotkeyManager.HotkeyID.capture.rawValue: "截图",
            HotkeyManager.HotkeyID.launcher.rawValue: "启动器",
            HotkeyManager.HotkeyID.clipboardHistory.rawValue: "剪贴板历史",
            HotkeyManager.HotkeyID.colorPicker.rawValue: "取色",
            HotkeyManager.HotkeyID.qrCode.rawValue: "二维码",
            HotkeyManager.HotkeyID.devTool.rawValue: "开发工具",
            HotkeyManager.HotkeyID.selectionBar.rawValue: "划词动作条",
        ]
        for item in settingsStore.launchItems {
            guard let hotkey = item.hotkey else { continue }
            bindings[item.hotkeySlot] = hotkey
            names[item.hotkeySlot] = item.name
        }

        // Registration is per-binding: one taken combination no longer kills the
        // others, it is just named in the alert and left unbound.
        let failed = hotkeyManager.reregister(bindings)
        if !failed.isEmpty {
            let details = failed.compactMap { id -> String? in
                guard let name = names[id], let hotkey = bindings[id] else { return nil }
                return "「\(name)」\(hotkey.displayText)"
            }
            let alert = NSAlert()
            alert.messageText = "快捷键注册失败"
            alert.informativeText = "\(details.joined(separator: "、")) 已被其它应用占用，" +
                "请换一个组合键。其余快捷键不受影响。"
            alert.runModal()
        }
        // The status menu shows the current capture binding and launch items.
        rebuildStatusMenu()
    }
}
