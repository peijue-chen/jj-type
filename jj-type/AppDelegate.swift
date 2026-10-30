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
        hotkeyManager = HotkeyManager(translate: store.translateHotkey,
                                      correct: store.correctHotkey)
        super.init()
    }

    private var statusItem: NSStatusItem?

    private let settingsStore: SettingsStore
    private let hotkeyManager: HotkeyManager
    private let textCapture = TextCaptureService()
    private let aiClient = AIClient()

    private var resultPanel: ResultPanelController?
    private var translationWindow: TranslationWindowController?
    private var settingsWindow: SettingsWindowController?
    private var inFlightTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        hotkeyManager.onTranslate = { [weak self] in
            MainActor.assumeIsolated { self?.runTranslationWindowFlow() }
        }
        hotkeyManager.onCorrectAndTranslate = { [weak self] in
            MainActor.assumeIsolated { self?.runPipeline(mode: .correctAndTranslate) }
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
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
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
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "辅助功能权限引导", action: #selector(openAccessibilityGuide),
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

    // MARK: - Hotkey changes

    /// Re-registers both hotkeys with REAL conflict detection via reregister()'s result.
    /// Triggered at launch (W1) and whenever SettingsStore persists a new binding (C1).
    private func reregisterHotkeys() {
        if let failed = hotkeyManager.reregister(translate: settingsStore.translateHotkey,
                                                 correct: settingsStore.correctHotkey) {
            let name = failed == .translate ? "翻译" : "纠正+翻译"
            let hotkey = failed == .translate ? settingsStore.translateHotkey : settingsStore.correctHotkey
            let alert = NSAlert()
            alert.messageText = "快捷键注册失败"
            // reregister is all-or-nothing: a failing binding unregisters BOTH hotkeys.
            alert.informativeText = "「\(name)」的 \(hotkey.displayText) 可能与其他应用冲突，请换一个组合键。" +
                "（两个快捷键目前已全部注销，更换后即恢复）"
            alert.runModal()
        }
    }
}
