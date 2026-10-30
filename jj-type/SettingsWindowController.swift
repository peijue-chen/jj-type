//
//  SettingsWindowController.swift
//  jj-type
//
//  Settings UI: provider CRUD (name / base URL / API key / model) with an
//  inline connection test, active provider selection and hotkey customization.
//

import AppKit

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

    private var translateRecorder: HotkeyRecorderView?
    private var correctRecorder: HotkeyRecorderView?

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
        // Constraints were added AFTER the contentViewController assignment, so the
        // window kept the content view's initial frame — snap it to the real fitting
        // size now that layout is fully defined.
        window.setContentSize(content.fittingSize)
    }

    // MARK: - Layout

    private func buildLayout(in view: NSView) {
        let providersTitle = sectionTitle("AI 服务（OpenAI 兼容）")

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

        let hotkeyTitle = sectionTitle("快捷键")
        let translate = HotkeyRecorderView(label: "翻译", hotkey: store.translateHotkey)
        let correct = HotkeyRecorderView(label: "纠正 + 翻译", hotkey: store.correctHotkey)
        translate.onHotkeyChanged = { [weak self] hotkey in self?.applyHotkey(.translate, hotkey) }
        correct.onHotkeyChanged = { [weak self] hotkey in self?.applyHotkey(.correctAndTranslate, hotkey) }
        translateRecorder = translate
        correctRecorder = correct
        let hotkeyHint = NSTextField(wrappingLabelWithString: "点击输入框后直接按下新组合键；需包含 ⌘/⌥/⌃ 至少一个修饰键。")
        hotkeyHint.font = .systemFont(ofSize: 11)
        hotkeyHint.textColor = .secondaryLabelColor

        let actionRow = NSStackView(views: [saveButton, testButton, activeButton])
        actionRow.spacing = 12

        let stack = NSStackView(views: [
            providersTitle, scroll,
            NSStackView(views: [addButton, deleteButton]),
            formGrid, actionRow, testResultLabel,
            hotkeyTitle, translate, correct, hotkeyHint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            // EQUAL (not lessThanOrEqual): the window must grow to fit every row.
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 110),
            scroll.widthAnchor.constraint(equalToConstant: 300),
            nameField.widthAnchor.constraint(equalToConstant: 300),
        ])
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 14, weight: .semibold)
        return field
    }

    private func formLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        return field
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
        guard let id = editingProviderId else { return }
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
    /// W2 fix: reject a binding identical to the other action's.
    private func applyHotkey(_ id: HotkeyManager.HotkeyID, _ hotkey: Hotkey) {
        let other = id == .translate ? store.correctHotkey : store.translateHotkey
        let recorder = id == .translate ? translateRecorder : correctRecorder
        if hotkey == other {
            recorder?.reject("与另一功能快捷键重复，请换一个组合键")
            return
        }
        if id == .translate {
            store.translateHotkey = hotkey
        } else {
            store.correctHotkey = hotkey
        }
        recorder?.accept()
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - NSTableView DataSource / Delegate

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        store.providers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let provider = store.providers[row]
        let isActive = provider.id == store.activeProviderId
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: isActive ? "● \(provider.name) — \(provider.model)"
                                                        : "○ \(provider.name) — \(provider.model)")
        text.font = .systemFont(ofSize: 12)
        cell.addSubview(text)
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        reloadForm()
    }
}
