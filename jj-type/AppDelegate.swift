//
//  AppDelegate.swift
//  jj-type
//
//  Menu-bar app lifecycle: status item, hotkeys, capture → AI → result pipeline.
//

import AppKit

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

    private var resultPanel: ResultPanelController?
    private var translationWindow: TranslationWindowController?
    private var launcherWindow: LauncherWindowController?
    private var settingsWindow: SettingsWindowController?
    private var inFlightTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[JJType] didFinishLaunching frontmost=%@",
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")
        resultPanel = ResultPanelController()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusIcon()

        rebuildStatusMenu()

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

        // Explicit startup registration so a hotkey conflict is surfaced, not swallowed (W1).
        reregisterHotkeys()

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
        NSLog("[JJType] reopen received, visible=%@ option=%@",
              flag ? "1" : "0", NSEvent.modifierFlags.contains(.option) ? "1" : "0")
        if NSEvent.modifierFlags.contains(.option) {
            openSettings()
            settingsWindow?.selectTerminalSection()
        } else {
            FinderTerminal.handleLaunch(coldLaunch: false)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Carbon hotkeys are released with the process; nothing to clean up manually.
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

    /// SF Symbol template image (adapts to light/dark menu bar) with a bulletproof
    /// text fallback: nil symbol OR zero-size image → visible "文A" title, always.
    private func configureStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = NSImage(systemSymbolName: "translate", accessibilityDescription: "JJType")
            ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "JJType")
            ?? NSImage(systemSymbolName: "character.textbox", accessibilityDescription: "JJType")
        if let symbol, symbol.size.width > 0, symbol.size.height > 0 {
            symbol.isTemplate = true
            symbol.size = NSSize(width: 18, height: 18)
            button.imageScaling = .scaleProportionallyDown
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
                    window.showResult(text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                window.showError(Self.errorMessage(for: error))
            }
        }
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
        ]
        var names: [UInt32: String] = [
            HotkeyManager.HotkeyID.translate.rawValue: "翻译",
            HotkeyManager.HotkeyID.correctAndTranslate.rawValue: "纠正+翻译",
            HotkeyManager.HotkeyID.capture.rawValue: "截图",
            HotkeyManager.HotkeyID.launcher.rawValue: "启动器",
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
