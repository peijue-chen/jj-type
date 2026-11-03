//
//  SettingsWindowController.swift
//  jj-type
//
//  Settings UI, split into pages (AI 服务 / 快捷键 / 截图) behind a segmented
//  header: provider CRUD (name / base URL / API key / model) with an inline
//  connection test, active provider selection, hotkey customization and the
//  screenshot output folder / format. New feature areas become new pages.
//  A shared footer shows the running version (MAJOR.MINOR.PATCH, from the
//  bundle) on every page.
//

import AppKit
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    private var store: SettingsStore!
    private let aiClient = AIClient()

    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let saveButton = NSButton(title: "保存更改", target: nil, action: nil)
    private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
    private let testResultLabel = NSTextField(labelWithString: "")
    private let activeButton = NSButton(checkboxWithTitle: "设为当前使用", target: nil, action: nil)
    private var editingProviderId: UUID?

    // MARK: - Tabs
    //
    // One page per feature group. Adding a feature area = add a title here and a
    // matching `make…Page()` in `buildLayout`; nothing else has to change.

    private let sectionControl = NSSegmentedControl(labels: ["AI 服务", "快捷键", "快捷启动", "截图"],
                                                    trackingMode: .selectOne,
                                                    target: nil,
                                                    action: nil)
    private let pageContainer = NSView()
    private var pages: [NSView] = []
    private weak var currentPage: NSView?
    private var pageConstraints: [NSLayoutConstraint] = []
    /// Version footer: shared by every page so the running build is always one
    /// glance away (three-part version, straight from the bundle).
    private let versionLabel = NSTextField(labelWithString: "")

    /// Every page uses the same content width, so the window does not change
    /// width when a tab is switched.
    private static let pageWidth: CGFloat = 520
    private static let pageMargin: CGFloat = 20

    private var translateRecorder: HotkeyRecorderView?
    private var correctRecorder: HotkeyRecorderView?
    private var captureRecorder: HotkeyRecorderView?
    private var launcherRecorder: HotkeyRecorderView?
    private let captureDirectoryLabel = NSTextField(labelWithString: "")
    private let captureFormatPopup = NSPopUpButton()

    // Launch items page (Alfred-style: one shortcut → one app/folder/file/URL).
    private let launchTable = NSTableView()
    private let launchNameField = NSTextField()
    private let launchKindPopup = NSPopUpButton()
    private let launchTargetField = NSTextField()
    private let launchChooseButton = NSButton(title: "选择…", target: nil, action: nil)
    private let launchSaveButton = NSButton(title: "保存更改", target: nil, action: nil)
    private var launchRecorder: HotkeyRecorderView?
    private var editingLaunchId: UUID?
    /// The launch-page hint quotes the current launcher shortcut, so it has to be
    /// rewritten when that binding changes.
    private var launchHintLabel: NSTextField?

    convenience init(store: SettingsStore) {
        // No fixed final frame — the content view is fully constraint-driven and
        // the window auto-sizes to its fitting size, so trailing stack items can
        // never be clipped (It8 root cause of the missing second recorder).
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 700))
        content.translatesAutoresizingMaskIntoConstraints = false
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentViewController = NSViewController()
        window.contentViewController?.view = content
        self.store = store
        buildLayout(in: content)
        reloadTable()
        reloadForm()
        reloadLaunchTable()
        reloadLaunchForm()
        // Constraints were added AFTER the contentViewController assignment, so the
        // window kept the content view's initial frame — snap it to the real fitting
        // size of the visible tab now that layout is fully defined.
        resizeWindowToFit()
    }

    // MARK: - Layout

    private func buildLayout(in view: NSView) {
        sectionControl.target = self
        sectionControl.action = #selector(sectionChanged)
        sectionControl.segmentStyle = .rounded
        sectionControl.selectedSegment = 0
        sectionControl.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<sectionControl.segmentCount {
            sectionControl.setWidth(96, forSegment: index)
        }

        pageContainer.translatesAutoresizingMaskIntoConstraints = false

        versionLabel.stringValue = Self.versionText
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .right
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let margin = Self.pageMargin
        view.addSubview(sectionControl)
        view.addSubview(pageContainer)
        view.addSubview(versionLabel)
        NSLayoutConstraint.activate([
            sectionControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            sectionControl.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            sectionControl.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor,
                                                     constant: -margin),
            pageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            pageContainer.topAnchor.constraint(equalTo: sectionControl.bottomAnchor, constant: 16),
            // Footer sits below the page and is part of the fitting size, so the
            // height recalculation on tab switch keeps it pinned to the bottom.
            pageContainer.bottomAnchor.constraint(equalTo: versionLabel.topAnchor, constant: -10),
            versionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            versionLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])

        pages = [makeProvidersPage(), makeHotkeyPage(), makeLaunchPage(), makeCapturePage()]
        if let first = pages.first {
            show(page: first)
        }
    }

    /// A page is a vertical stack pinned to the container; the window height is
    /// derived from its fitting size, so a new row can never be clipped.
    private func makePage(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeHint(_ text: String) -> NSTextField {
        let hint = NSTextField(wrappingLabelWithString: text)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: Self.pageWidth).isActive = true
        return hint
    }

    // MARK: - Pages

    /// Page 1: OpenAI-compatible provider CRUD.
    private func makeProvidersPage() -> NSStackView {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        tableColumn.title = "服务"
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "新建", target: self, action: #selector(addProvider))
        let deleteButton = NSButton(title: "删除", target: self, action: #selector(deleteProvider))
        let listRow = NSStackView(views: [addButton, deleteButton])
        listRow.spacing = 8

        let formGrid = NSGridView(views: [
            [formLabel("名称"), nameField],
            [formLabel("Base URL（含 /v1）"), baseURLField],
            [formLabel("API Key"), apiKeyField],
            [formLabel("模型名"), modelField],
        ])
        formGrid.column(at: 0).xPlacement = .trailing
        formGrid.rowSpacing = 8
        formGrid.translatesAutoresizingMaskIntoConstraints = false

        saveButton.target = self
        saveButton.action = #selector(saveProvider)
        saveButton.bezelStyle = .rounded

        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded
        testResultLabel.font = .systemFont(ofSize: 11)
        testResultLabel.lineBreakMode = .byTruncatingTail

        activeButton.target = self
        activeButton.action = #selector(toggleActive(_:))

        let actionRow = NSStackView(views: [saveButton, testButton, activeButton])
        actionRow.spacing = 12

        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 120),
            scroll.widthAnchor.constraint(equalToConstant: Self.pageWidth),
        ])

        return makePage([
            makeHint("OpenAI 兼容接口：Base URL 需含 /v1，API Key 只保存在系统钥匙串。"),
            scroll, listRow, formGrid, actionRow, testResultLabel,
        ])
    }

    /// Page 2: global hotkey rebinding.
    private func makeHotkeyPage() -> NSStackView {
        let translate = HotkeyRecorderView(label: "翻译", hotkey: store.translateHotkey)
        let correct = HotkeyRecorderView(label: "纠正 + 翻译", hotkey: store.correctHotkey)
        let capture = HotkeyRecorderView(label: "截图", hotkey: store.captureHotkey)
        let launcher = HotkeyRecorderView(label: "启动器", hotkey: store.launcherHotkey)
        translate.onHotkeyChanged = { [weak self] hotkey in self?.applyHotkey(.translate, hotkey) }
        correct.onHotkeyChanged = { [weak self] hotkey in self?.applyHotkey(.correctAndTranslate, hotkey) }
        capture.onHotkeyChanged = { [weak self] hotkey in self?.applyHotkey(.capture, hotkey) }
        launcher.onHotkeyChanged = { [weak self] hotkey in self?.applyHotkey(.launcher, hotkey) }
        translateRecorder = translate
        correctRecorder = correct
        captureRecorder = capture
        launcherRecorder = launcher

        return makePage([
            translate, correct, capture, launcher,
            makeHint("点击输入框后直接按下新组合键；需包含 ⌘/⌥/⌃ 至少一个修饰键。"),
        ])
    }

    /// Page 3: launch items — one global shortcut per app / folder / file / URL.
    private func makeLaunchPage() -> NSStackView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("launch"))
        column.title = "项目"
        launchTable.addTableColumn(column)
        launchTable.headerView = nil
        launchTable.delegate = self
        launchTable.dataSource = self
        launchTable.selectionHighlightStyle = .regular
        launchTable.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.documentView = launchTable
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 120),
            scroll.widthAnchor.constraint(equalToConstant: Self.pageWidth),
        ])

        let addButton = NSButton(title: "新建", target: self, action: #selector(addLaunchItem))
        let deleteButton = NSButton(title: "删除", target: self, action: #selector(deleteLaunchItem))
        addButton.bezelStyle = .rounded
        deleteButton.bezelStyle = .rounded
        let listRow = NSStackView(views: [addButton, deleteButton])
        listRow.spacing = 8

        launchKindPopup.addItems(withTitles: LaunchTargetKind.allCases.map(\.displayName))
        launchKindPopup.target = self
        launchKindPopup.action = #selector(launchKindChanged)

        launchTargetField.widthAnchor.constraint(equalToConstant: 286).isActive = true
        launchChooseButton.bezelStyle = .rounded
        launchChooseButton.target = self
        launchChooseButton.action = #selector(chooseLaunchTarget)
        let targetRow = NSStackView(views: [launchTargetField, launchChooseButton])
        targetRow.spacing = 8

        let recorder = HotkeyRecorderView(label: "快捷键", hotkey: nil, allowsClearing: true)
        recorder.onHotkeyChanged = { [weak self] hotkey in self?.applyLaunchHotkey(hotkey) }
        recorder.onHotkeyCleared = { [weak self] in self?.applyLaunchHotkey(nil) }
        launchRecorder = recorder

        launchSaveButton.bezelStyle = .rounded
        launchSaveButton.target = self
        launchSaveButton.action = #selector(saveLaunchItem)
        launchSaveButton.isEnabled = false

        let grid = NSGridView(views: [
            [formLabel("名称"), launchNameField],
            [formLabel("类型"), launchKindPopup],
            [formLabel("目标"), targetRow],
            [formLabel("快捷键"), recorder],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let hint = makeHint(Self.launchHintText(launcherHotkey: store.launcherHotkey))
        launchHintLabel = hint

        return makePage([
            hint, scroll, listRow, grid, launchSaveButton,
            makeHint("App 按 Bundle ID 记录，移动位置后仍可用；文件夹 / 文件按绝对路径记录。快捷键留空即只用菜单打开。"),
        ])
    }

    private static func launchHintText(launcherHotkey: Hotkey) -> String {
        "给任意 App、文件夹、文件或网址绑定一个全局快捷键；也可以按 "
            + "\(launcherHotkey.displayText) 打开启动器，输入名字筛选后回车。"
    }

    /// Page 4: screenshot output (folder / format).
    private func makeCapturePage() -> NSStackView {
        makePage([
            buildCaptureGrid(),
            makeHint("截图需要「屏幕录制」权限；首次授权后需重启 JJType 才会生效。"),
        ])
    }

    // MARK: - Tab switching

    @objc private func sectionChanged() {
        let index = sectionControl.selectedSegment
        guard index >= 0, index < pages.count else { return }
        show(page: pages[index])
        resizeWindowToFit()
    }

    private func show(page: NSView) {
        guard page !== currentPage else { return }
        // Explicit deactivate: AppKit's cleanup of constraints that reference a
        // removed subview is not something to depend on.
        NSLayoutConstraint.deactivate(pageConstraints)
        pageConstraints = [
            page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            // EQUAL (not lessThanOrEqual): the window must grow to fit every row.
            page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ]
        currentPage?.removeFromSuperview()
        pageContainer.addSubview(page)
        NSLayoutConstraint.activate(pageConstraints)
        currentPage = page
    }

    /// Each tab has its own height: resize the window and keep its top edge in
    /// place so the title bar does not jump when switching.
    private func resizeWindowToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let size = NSSize(width: max(Self.pageWidth + Self.pageMargin * 2, fitting.width),
                          height: max(160, fitting.height))
        let top = window.frame.maxY
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }

    /// `JJType 1.1.0 (2)` — three-part marketing version plus the build number.
    /// Both come from the bundle (MARKETING_VERSION / CURRENT_PROJECT_VERSION),
    /// never from a hard-coded literal that could drift from the build.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return "JJType \(version)"
        }
        return "JJType \(version) (\(build))"
    }

    private func formLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        return field
    }

    /// Screenshot section: folder picker + image format.
    private func buildCaptureGrid() -> NSGridView {
        captureDirectoryLabel.font = .systemFont(ofSize: 12)
        captureDirectoryLabel.textColor = .secondaryLabelColor
        captureDirectoryLabel.lineBreakMode = .byTruncatingMiddle
        captureDirectoryLabel.stringValue = store.captureSaveDirectory.path
        captureDirectoryLabel.widthAnchor.constraint(equalToConstant: 210).isActive = true

        let chooseButton = NSButton(title: "选择…", target: self, action: #selector(chooseCaptureDirectory))
        chooseButton.bezelStyle = .rounded

        captureFormatPopup.addItems(withTitles: CaptureFormat.allCases.map { $0.displayName })
        if let index = CaptureFormat.allCases.firstIndex(of: store.captureFormat) {
            captureFormatPopup.selectItem(at: index)
        }
        captureFormatPopup.target = self
        captureFormatPopup.action = #selector(captureFormatChanged)

        let grid = NSGridView(views: [
            [formLabel("保存目录"), captureDirectoryLabel, chooseButton],
            [formLabel("图片格式"), captureFormatPopup, NSGridCell.emptyContentView],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    // MARK: - Data binding

    private func reloadTable() {
        tableView.reloadData()
    }

    private func reloadForm() {
        let row = tableView.selectedRow
        guard row >= 0, row < store.providers.count else {
            editingProviderId = nil
            [nameField, baseURLField, apiKeyField, modelField].forEach { $0.stringValue = "" }
            apiKeyField.placeholderString = "sk-…"
            saveButton.isEnabled = false
            activeButton.isEnabled = false
            activeButton.state = .off
            return
        }
        let provider = store.providers[row]
        editingProviderId = provider.id
        nameField.stringValue = provider.name
        baseURLField.stringValue = provider.baseURL
        modelField.stringValue = provider.model
        apiKeyField.stringValue = ""
        apiKeyField.placeholderString = "已保存（输入可更换）"
        saveButton.isEnabled = true
        activeButton.isEnabled = true
        activeButton.state = provider.id == store.activeProviderId ? .on : .off
    }

    // MARK: - Launch item binding

    /// Reloading clears the table selection; restore it from the edited item so
    /// the form and the highlighted row never drift apart.
    private func reloadLaunchTable() {
        launchTable.reloadData()
        guard let id = editingLaunchId,
              let row = store.launchItems.firstIndex(where: { $0.id == id }) else { return }
        launchTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // A freshly appended item must be visible, not merely selected.
        launchTable.scrollRowToVisible(row)
    }

    /// The row the user has selected right now (read live: after `reloadData`
    /// AppKit posts a DELAYED empty-selection notification).
    private var selectedLaunchItem: LaunchItem? {
        let row = launchTable.selectedRow
        guard row >= 0, row < store.launchItems.count else { return nil }
        return store.launchItems[row]
    }

    /// The item the form is bound to. The cached id WINS and is never dropped by
    /// a selection refresh: `reloadData()` fires a delayed "selection is empty"
    /// notification that used to clear it, so freshly added items could not get
    /// a shortcut ("请先在列表中选择一个项目").
    private var editingLaunchItem: LaunchItem? {
        if let id = editingLaunchId, let item = store.launchItems.first(where: { $0.id == id }) {
            return item
        }
        return selectedLaunchItem
    }

    /// Mirrors the edited item into the form; nothing to edit clears every field
    /// so a stale id can never be saved onto another item.
    private func reloadLaunchForm() {
        guard let item = editingLaunchItem else {
            editingLaunchId = nil
            launchNameField.stringValue = ""
            launchKindPopup.selectItem(at: 0)
            launchTargetField.stringValue = ""
            launchRecorder?.setHotkey(nil)
            launchSaveButton.isEnabled = false
            updateLaunchTargetUI()
            return
        }
        editingLaunchId = item.id
        launchNameField.stringValue = item.name
        launchKindPopup.selectItem(at: LaunchTargetKind.allCases.firstIndex(of: item.kind) ?? 0)
        launchTargetField.stringValue = item.target
        launchRecorder?.setHotkey(item.hotkey)
        launchSaveButton.isEnabled = true
        updateLaunchTargetUI()
    }

    private var selectedLaunchKind: LaunchTargetKind {
        let index = launchKindPopup.indexOfSelectedItem
        guard index >= 0, index < LaunchTargetKind.allCases.count else { return .application }
        return LaunchTargetKind.allCases[index]
    }

    private func updateLaunchTargetUI() {
        let kind = selectedLaunchKind
        launchChooseButton.isEnabled = kind != .url
        switch kind {
        case .url:
            launchTargetField.placeholderString = "https://example.com"
        case .application:
            launchTargetField.placeholderString = "Bundle ID 或 .app 路径"
        case .folder, .file:
            launchTargetField.placeholderString = "绝对路径"
        }
    }

    // MARK: - Actions

    @objc private func addProvider() {
        let provider = ProviderConfig(id: UUID(), name: "新服务",
                                      baseURL: "https://api.example.com/v1", model: "gpt-4o-mini")
        // Keychain-first: on failure nothing is stored — abort before touching the table.
        do {
            try store.addProvider(provider, apiKey: "")
        } catch {
            showAlert("新增失败", (error as? LocalizedError)?.errorDescription
                ?? "钥匙串写入失败，请重试")
            return
        }
        reloadTable()
        let index = store.providers.firstIndex { $0.id == provider.id } ?? 0
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        reloadForm()
    }

    @objc private func deleteProvider() {
        guard let id = editingProviderId,
              let provider = store.providers.first(where: { $0.id == id }) else { return }
        // Deleting also drops the API key from the Keychain — unrecoverable, so
        // it must never happen on a single stray click.
        let alert = NSAlert()
        alert.messageText = "删除「\(provider.name)」？"
        alert.informativeText = "该服务保存在钥匙串里的 API Key 会被一起删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteProvider(id: id)
        reloadTable()
        if !store.providers.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        reloadForm()
    }

    @objc private func saveProvider() {
        guard let id = editingProviderId,
              var provider = store.providers.first(where: { $0.id == id }) else { return }
        provider.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.updateProvider(provider, apiKey: trimmedKey.isEmpty ? nil : trimmedKey)
        } catch {
            showAlert("保存失败", (error as? LocalizedError)?.errorDescription
                ?? "钥匙串写入出错，Key 可能未保存，请重新填写后再次保存。")
            return
        }
        reloadTable()
        saveButton.title = "已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.saveButton.title = "保存更改"
        }
    }

    /// Fires a minimal chat-completions probe using the CURRENT form values
    /// (works before saving). Falls back to the saved Keychain key when the
    /// secure field is left untouched.
    @objc private func testConnection() {
        let baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, !model.isEmpty else {
            showTestResult(false, "请先填写 Base URL 与模型名")
            return
        }
        let typedKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var savedKey = ""
        if let id = editingProviderId {
            savedKey = KeychainStore.loadAPIKey(for: id) ?? ""
        }
        let apiKey = typedKey.isEmpty ? savedKey : typedKey
        guard !apiKey.isEmpty else {
            showTestResult(false, "请先填写 API Key")
            return
        }

        let provider = ProviderConfig(id: editingProviderId ?? UUID(), name: nameField.stringValue,
                                      baseURL: baseURL, model: model)
        testButton.isEnabled = false
        testButton.title = "测试中…"
        let client = aiClient
        Task { @MainActor in
            do {
                let elapsed = try await client.testConnection(provider: provider, apiKey: apiKey)
                self.showTestResult(true, "连接成功（模型 \(provider.model)，耗时 \(elapsed)ms）")
            } catch {
                self.showTestResult(false, self.testFailureMessage(error))
            }
            self.testButton.isEnabled = true
            self.testButton.title = "测试连接"
        }
    }

    private func showTestResult(_ success: Bool, _ message: String) {
        testResultLabel.textColor = success ? .systemGreen : .systemRed
        testResultLabel.stringValue = (success ? "✅ " : "❌ ") + message
    }

    /// Maps common failure shapes to friendly Chinese reasons.
    private func testFailureMessage(_ error: Error) -> String {
        guard let aiError = error as? AIError else {
            return "失败：\(error.localizedDescription)"
        }
        switch aiError {
        case .invalidURL:
            return "Base URL 格式无效，请检查"
        case .http(let status, let message):
            if status == 401 || status == 403 {
                return "认证失败（HTTP \(status)）：API Key 无效或无权限"
            }
            if status == 404 {
                return "地址不存在（HTTP 404）：请检查 Base URL（需含 /v1）与模型名"
            }
            if message.lowercased().contains("model") {
                return "模型不存在或无权访问：\(message)"
            }
            return "请求失败（HTTP \(status)）：\(message)"
        case .network(let message):
            return "网络错误：\(message)（请检查网络与 Base URL）"
        case .noValidResult, .malformedResponse:
            return aiError.errorDescription ?? "未知错误"
        }
    }

    @objc private func toggleActive(_ sender: NSButton) {
        guard let id = editingProviderId else { return }
        store.setActiveProvider(id: id)
        reloadTable()
    }

    /// C1 fix: persist via the store setter so SettingsStore fires onHotkeyChanged
    /// → AppDelegate.reregisterHotkeys() performs REAL conflict detection and alerts.
    /// W2 fix: reject a binding already used by any other action.
    private func applyHotkey(_ id: HotkeyManager.HotkeyID, _ hotkey: Hotkey) {
        guard let recorder = recorder(for: id) else { return }
        // Every other built-in action counts as a conflict; launch items are
        // checked separately on their own page.
        let others = HotkeyManager.HotkeyID.allCases.filter { $0 != id }
        if others.contains(where: { actionHotkey($0) == hotkey }) {
            recorder.reject("与其它功能快捷键重复，请换一个组合键")
            return
        }
        // Launch items are just as real a binding: a duplicate would pass this
        // check, then fail at Carbon registration time and leave one action dead.
        if let item = store.launchItems.first(where: { $0.hotkey == hotkey }) {
            recorder.reject("与快捷启动「\(item.name)」的快捷键重复，请换一个组合键")
            return
        }
        setActionHotkey(hotkey, for: id)
        recorder.accept()
    }

    private func actionHotkey(_ id: HotkeyManager.HotkeyID) -> Hotkey {
        switch id {
        case .translate: return store.translateHotkey
        case .correctAndTranslate: return store.correctHotkey
        case .capture: return store.captureHotkey
        case .launcher: return store.launcherHotkey
        }
    }

    private func setActionHotkey(_ hotkey: Hotkey, for id: HotkeyManager.HotkeyID) {
        switch id {
        case .translate: store.translateHotkey = hotkey
        case .correctAndTranslate: store.correctHotkey = hotkey
        case .capture: store.captureHotkey = hotkey
        case .launcher:
            store.launcherHotkey = hotkey
            launchHintLabel?.stringValue = Self.launchHintText(launcherHotkey: hotkey)
        }
    }

    private func recorder(for id: HotkeyManager.HotkeyID) -> HotkeyRecorderView? {
        switch id {
        case .translate: return translateRecorder
        case .correctAndTranslate: return correctRecorder
        case .capture: return captureRecorder
        case .launcher: return launcherRecorder
        }
    }

    @objc private func chooseCaptureDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.captureSaveDirectory
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.captureSaveDirectory = url
        captureDirectoryLabel.stringValue = store.captureSaveDirectory.path
    }

    @objc private func captureFormatChanged() {
        let index = captureFormatPopup.indexOfSelectedItem
        guard index >= 0, index < CaptureFormat.allCases.count else { return }
        store.captureFormat = CaptureFormat.allCases[index]
    }

    // MARK: - Launch item actions

    @objc private func addLaunchItem() {
        let item = LaunchItem(id: UUID(), name: "新项目", kind: .application, target: "",
                              hotkeySlot: store.nextLaunchHotkeySlot, hotkey: nil)
        store.addLaunchItem(item)
        // Bind the form BEFORE the reload: `reloadData()` clears the selection
        // and only restores it from this id.
        editingLaunchId = item.id
        reloadLaunchTable()
        reloadLaunchForm()
        window?.makeFirstResponder(launchNameField)
    }

    @objc private func deleteLaunchItem() {
        guard let item = editingLaunchItem else { return }
        store.deleteLaunchItem(id: item.id)
        editingLaunchId = nil
        reloadLaunchTable()
        if !store.launchItems.isEmpty {
            launchTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        reloadLaunchForm()
    }

    /// Name / kind / target are saved here; the shortcut is applied immediately
    /// by the recorder (it has to be live to be validated).
    @objc private func saveLaunchItem() {
        guard var item = editingLaunchItem else { return }
        let name = launchNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = launchTargetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showAlert("无法保存", "请填写名称")
            return
        }
        guard !target.isEmpty else {
            showAlert("无法保存", "请填写或选择一个打开目标")
            return
        }
        item.name = name
        item.kind = selectedLaunchKind
        item.target = target
        // A target that resolves to nothing would only ever produce an error
        // alert from the shortcut, so ask before storing it.
        guard item.resolvedURL != nil || confirmUnresolvableTarget(target) else { return }
        editingLaunchId = item.id
        store.updateLaunchItem(item)
        reloadLaunchTable()
        if let index = store.launchItems.firstIndex(where: { $0.id == item.id }) {
            launchTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        reloadLaunchForm()
        launchSaveButton.title = "已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.launchSaveButton.title = "保存更改"
        }
    }

    @objc private func launchKindChanged() {
        updateLaunchTargetUI()
    }

    /// App → store the bundle id (survives moving/renaming the .app); folder /
    /// file → absolute path. The name is auto-filled from the picker only while
    /// it is still the placeholder, so a typed name is never overwritten.
    @objc private func chooseLaunchTarget() {
        let kind = selectedLaunchKind
        guard kind != .url else { return }
        let panel = NSOpenPanel()
        switch kind {
        case .application:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .folder:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
        case .file:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
        case .url:
            return
        }
        panel.canCreateDirectories = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch kind {
        case .application:
            launchTargetField.stringValue = Bundle(url: url)?.bundleIdentifier ?? url.path
        case .folder, .file:
            launchTargetField.stringValue = url.path
        case .url:
            return
        }
        let placeholderNames = ["", "新项目", kind.displayName]
        if placeholderNames.contains(launchNameField.stringValue) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            launchNameField.stringValue = name
        }
    }

    /// Persists the recording immediately; nil means "cleared" (allowed here,
    /// unlike the three built-in actions).
    private func applyLaunchHotkey(_ hotkey: Hotkey?) {
        guard var item = editingLaunchItem else {
            launchRecorder?.reject("请先点「新建」或在上方列表中选中一个项目")
            return
        }
        if let hotkey, let conflict = conflictingActionName(for: hotkey, excluding: item.id) {
            launchRecorder?.reject("与「\(conflict)」的快捷键重复，请换一个组合键")
            return
        }
        // Pick up the name / kind / target the user already typed: recording a
        // shortcut must not persist a half-empty item that can never open.
        let typedName = launchNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedTarget = launchTargetField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedName.isEmpty { item.name = typedName }
        if !typedTarget.isEmpty { item.target = typedTarget }
        item.kind = selectedLaunchKind
        item.hotkey = hotkey
        editingLaunchId = item.id
        store.updateLaunchItem(item)
        launchRecorder?.accept()
        // Refresh just this row. A full `reloadData()` would clear the selection
        // and re-run the form binding, which throws away a name the user typed
        // but has not saved yet.
        reloadLaunchRow(id: item.id)
    }

    /// Rewrites one row's text in place (shortcut column) without touching the
    /// table's selection or the form.
    private func reloadLaunchRow(id: UUID) {
        guard let row = store.launchItems.firstIndex(where: { $0.id == id }),
              row < launchTable.numberOfRows else { return }
        launchTable.reloadData(forRowIndexes: IndexSet(integer: row),
                               columnIndexes: IndexSet(integer: 0))
    }

    private func conflictingActionName(for hotkey: Hotkey, excluding id: UUID) -> String? {
        if store.translateHotkey == hotkey { return "翻译" }
        if store.correctHotkey == hotkey { return "纠正 + 翻译" }
        if store.captureHotkey == hotkey { return "截图" }
        if store.launcherHotkey == hotkey { return "启动器" }
        return store.launchItems.first { $0.id != id && $0.hotkey == hotkey }?.name
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// True when the user wants to keep a target that cannot be resolved right
    /// now (moved file, unmounted volume, typo).
    private func confirmUnresolvableTarget(_ target: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "目标暂时不可用"
        alert.informativeText = "现在找不到「\(target)」，可能已被移动、删除，" +
            "或所在磁盘未挂载。仍要保存吗？"
        alert.addButton(withTitle: "仍然保存")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - NSTableView DataSource / Delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === launchTable ? store.launchItems.count : store.providers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === launchTable {
            let item = store.launchItems[row]
            let shortcut = item.hotkey.map { "  \($0.displayText)" } ?? "  未设快捷键"
            return makeCell(text: "\(item.name) — \(item.kind.displayName)\(shortcut)")
        }
        let provider = store.providers[row]
        let isActive = provider.id == store.activeProviderId
        return makeCell(text: isActive ? "● \(provider.name) — \(provider.model)"
                                       : "○ \(provider.name) — \(provider.model)")
    }

    private func makeCell(text value: String) -> NSView {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: value)
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === launchTable {
            // A real click adopts the row; an EMPTY selection is the delayed
            // post-`reloadData` artifact and must keep the current binding, or
            // the form would lose its item right after 新建 / 保存.
            if let item = selectedLaunchItem { editingLaunchId = item.id }
            reloadLaunchForm()
        } else {
            reloadForm()
        }
    }
}
