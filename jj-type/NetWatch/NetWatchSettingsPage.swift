//
//  NetWatchSettingsPage.swift
//  jj-type
//
//  「网络守护」settings page. Four cards: status/switch, backup Wi-Fi,
//  detection + VPN + app, and webhook. The page is a fixed-height scroll
//  container so the settings window never grows past the screen.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
final class NetWatchSettingsPage: NSObject, NSTextFieldDelegate {
    let view: NSScrollView

    private let service: NetWatchService
    private var config: NetWatchConfig
    /// The SSID whose password is currently in the field. When the user edits
    /// the SSID, the password no longer belongs to it and must not be written
    /// under the new name (that would silently corrupt another network's key).
    private var passwordOwnerSSID: String = ""

    // Status
    private let enabledToggle = NSButton(checkboxWithTitle: "启用网络守护", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let checkButton = Theme.button("立即检查", symbol: "arrow.clockwise")
    private let switchButton = Theme.button("立即切换备用网络", symbol: "wifi.exclamationmark")

    // Backup Wi-Fi
    private let ssidField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let interfaceField = NSTextField()
    private let wifiStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let wifiCheckButton = Theme.button("检测当前 Wi-Fi", symbol: "wifi")

    // Detection
    private let intervalField = NSTextField()
    private let outageField = NSTextField()
    private let cooldownField = NSTextField()
    private let overseasURLField = NSTextField()
    private let domesticURLField = NSTextField()

    // VPN
    private let vpnToggle = NSButton(checkboxWithTitle: "恢复后测试 VPN", target: nil, action: nil)
    private let vpnPathField = NSTextField()
    private let vpnChooseButton = Theme.button("选择…", symbol: "folder")
    private let vpnGraceField = NSTextField()
    private let vpnTestButton = Theme.button("立即测试 VPN", symbol: "lock.shield")

    // App
    private let appToggle = NSButton(checkboxWithTitle: "恢复后打开指定 App", target: nil, action: nil)
    private let appPopup = NSPopUpButton()
    private let appChooseButton = Theme.button("选择…", symbol: "folder")

    // Webhook
    private let webhookToggle = NSButton(checkboxWithTitle: "启用 Webhook 通知", target: nil, action: nil)
    private let webhookField = NSTextField()
    private let notifySuccessToggle = NSButton(checkboxWithTitle: "成功时通知", target: nil, action: nil)
    private let notifyFailureToggle = NSButton(checkboxWithTitle: "失败时通知", target: nil, action: nil)
    private let heartbeatToggle = NSButton(checkboxWithTitle: "定期发送「守护进程运行中」通知", target: nil, action: nil)
    private let heartbeatIntervalField = NSTextField()
    private let webhookTestButton = Theme.button("发送测试通知", symbol: "paperplane")
    private let webhookResultLabel = NSTextField(wrappingLabelWithString: "")

    private static let contentWidth: CGFloat = 540
    private static let cardContentWidth: CGFloat = contentWidth - Theme.cardPadding * 2

    /// Number fields skipped by `controlTextDidChange` (see there).
    private var numberFields: [NSTextField] {
        [intervalField, outageField, cooldownField, vpnGraceField, heartbeatIntervalField]
    }

    init(service: NetWatchService) {
        self.service = service
        self.config = service.config
        self.view = NSScrollView()
        super.init()
        build()
        refreshAll()
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged),
            name: .netWatchStatusChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Build

    private func build() {
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.drawsBackground = false
        view.borderType = .noBorder
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 520).isActive = true

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        view.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: view.contentView.widthAnchor),
        ])

        for card in [statusCard(), wifiCard(), detectionCard(), vpnCard(), appCard(), webhookCard()] {
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }
    }

    private func statusCard() -> CardView {
        let card = Theme.card()
        card.content.addArrangedSubview(header("状态"))

        enabledToggle.target = self
        enabledToggle.action = #selector(controlChanged)
        card.content.addArrangedSubview(enabledToggle)

        statusLabel.font = Theme.bodyMedium()
        statusLabel.maximumNumberOfLines = 0
        statusLabel.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        card.content.addArrangedSubview(statusLabel)

        checkButton.target = self
        checkButton.action = #selector(checkNow)
        switchButton.target = self
        switchButton.action = #selector(switchNow)
        let buttons = NSStackView(views: [checkButton, switchButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        card.content.addArrangedSubview(buttons)

        card.content.addArrangedSubview(hint("守护随 JJType 运行；建议在「通用」中开启开机自启，并配合防休眠使用。"))
        return card
    }

    private func wifiCard() -> CardView {
        let card = Theme.card()
        card.content.addArrangedSubview(header("备用 Wi-Fi"))

        ssidField.placeholderString = "备用 Wi-Fi 名称（SSID）"
        ssidField.delegate = self
        pin(ssidField)

        passwordField.placeholderString = "密码（保存在钥匙串）"
        passwordField.delegate = self
        pin(passwordField)

        interfaceField.placeholderString = "自动（\(NetWatchProbe.detectWiFiInterface())）"
        interfaceField.delegate = self
        pin(interfaceField)

        card.content.addArrangedSubview(formGrid([
            ("SSID", ssidField),
            ("密码", passwordField),
            ("网卡", interfaceField),
        ]))

        wifiCheckButton.target = self
        wifiCheckButton.action = #selector(checkWiFi)
        card.content.addArrangedSubview(wifiCheckButton)

        wifiStatusLabel.font = Theme.caption()
        wifiStatusLabel.textColor = .secondaryLabelColor
        wifiStatusLabel.maximumNumberOfLines = 0
        wifiStatusLabel.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        card.content.addArrangedSubview(wifiStatusLabel)

        card.content.addArrangedSubview(hint("断网达到阈值后，JJType 会先打开 Wi-Fi（若处于关闭状态），等无线电就绪再连接这个网络。密码只写入钥匙串，不落配置文件。"))
        return card
    }

    private func detectionCard() -> CardView {
        let card = Theme.card()
        card.content.addArrangedSubview(header("检测与切换"))

        configureNumberField(intervalField, value: config.checkIntervalSeconds)
        configureNumberField(outageField, value: config.outageThresholdSeconds)
        configureNumberField(cooldownField, value: config.switchCooldownSeconds)
        overseasURLField.delegate = self
        pin(overseasURLField)
        domesticURLField.delegate = self
        pin(domesticURLField)

        card.content.addArrangedSubview(formGrid([
            ("检查间隔（秒）", intervalField),
            ("断网判定（秒）", outageField),
            ("切换冷却（秒）", cooldownField),
            ("国外链接", overseasURLField),
            ("国内链接", domesticURLField),
        ]))

        card.content.addArrangedSubview(fieldExplanation("检查间隔",
            "多久做一次网络探测。默认 30 秒。调小响应更快、更耗电；调大更省电但发现断网更慢。"))
        card.content.addArrangedSubview(fieldExplanation("断网判定",
            "连续多久探测失败才认为「真的断网」并开始切换备用网络。默认 600 秒（10 分钟）。设置它是为了避免路由器瞬断、DNS 抖动这类几秒的网络波动就触发切网。"))
        card.content.addArrangedSubview(fieldExplanation("切换冷却",
            "两次切换备用网络之间的最短间隔。默认 300 秒（5 分钟）。切换失败后不会立刻反复重试，避免 Wi-Fi 被反复断开重连。"))
        card.content.addArrangedSubview(fieldExplanation("三层探测",
            "① 先看物理链路（有网卡、网关能 ping 通）。连链路都不通时不会发任何请求，直接走「备用网络 → OpenVPN」。\n"
            + "② 再打开**国外链接**：能打开就说明出国的路是通的，判定健康。\n"
            + "③ 国外打不开时，才进一步测**国内链接**：国内通 → 只重启 OpenVPN，不动网络；国内也不通 → 判定断网，切备用网络。\n"
            + "只要能返回任意 HTTP 状态码（含 302）就算通，只有连接失败/超时才判定不通。"))
        return card
    }

    /// A form field explanation: bold label line + wrapped description.
    private func fieldExplanation(_ title: String, _ text: String) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.textColor = .secondaryLabelColor
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 11)
        body.textColor = .tertiaryLabelColor
        body.maximumNumberOfLines = 0
        body.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        let stack = NSStackView(views: [name, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    private func vpnCard() -> CardView {
        let card = Theme.card()
        card.content.addArrangedSubview(header("VPN"))

        vpnToggle.target = self
        vpnToggle.action = #selector(controlChanged)
        card.content.addArrangedSubview(vpnToggle)

        vpnPathField.delegate = self
        pin(vpnPathField)
        vpnChooseButton.target = self
        vpnChooseButton.action = #selector(chooseVPNPath)
        let pathRow = NSStackView(views: [vpnPathField, vpnChooseButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8

        configureNumberField(vpnGraceField, value: config.vpnGraceSeconds)

        // No "VPN 服务" field: whether the tunnel works is decided by the
        // overseas LINK, so any VPN client (or a network that is itself a VPN)
        // is handled without naming a system VPN service.
        card.content.addArrangedSubview(formGrid([
            ("App 路径", pathRow),
            ("断开阈值（秒）", vpnGraceField),
        ]))

        vpnTestButton.target = self
        vpnTestButton.action = #selector(testVPN)
        card.content.addArrangedSubview(vpnTestButton)

        card.content.addArrangedSubview(fieldExplanation("断开阈值",
            "VPN 连续断开多久才去重启它。默认 120 秒。设短了会在 VPN 自己重连的过程中被强行打断；设长了则恢复更慢。"))
        card.content.addArrangedSubview(fieldExplanation("连接方式",
            "OpenVPN Connect 没有命令行「连接」指令，所以这里是先退出 App，再用完整路径重新启动，靠它开机/启动即自动连接的特性建立隧道，最多等待 60 秒。"))
        return card
    }

    private func appCard() -> CardView {
        let card = Theme.card()
        card.content.addArrangedSubview(header("恢复后打开 App"))

        appToggle.target = self
        appToggle.action = #selector(controlChanged)
        card.content.addArrangedSubview(appToggle)

        appPopup.target = self
        appPopup.action = #selector(controlChanged)
        appPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        appChooseButton.target = self
        appChooseButton.action = #selector(chooseApp)
        let row = NSStackView(views: [appPopup, appChooseButton])
        row.orientation = .horizontal
        row.spacing = 8
        card.content.addArrangedSubview(row)

        card.content.addArrangedSubview(hint("网络恢复（并完成 VPN 检查）后打开这个 App，每次恢复只执行一次。"))
        return card
    }

    private func webhookCard() -> CardView {
        let card = Theme.card()
        card.content.addArrangedSubview(header("通知"))

        webhookToggle.target = self
        webhookToggle.action = #selector(controlChanged)
        card.content.addArrangedSubview(webhookToggle)

        webhookField.placeholderString = "https://…"
        webhookField.delegate = self
        // Full width instead of a 300 pt box: webhook URLs carry a long token
        // that was being cut off in the middle, making it impossible to check
        // which channel the notification goes to. The stored value was always
        // complete — only the view was narrow.
        webhookField.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        // Horizontal scrolling keeps the caret and the END of the token reachable
        // while editing a value longer than the field.
        webhookField.cell?.isScrollable = true
        webhookField.cell?.wraps = false
        card.content.addArrangedSubview(webhookField)
        webhookField.toolTip = "完整地址会原样保存；这里显示不下时可以用方向键滚动查看"

        notifySuccessToggle.target = self
        notifySuccessToggle.action = #selector(controlChanged)
        notifyFailureToggle.target = self
        notifyFailureToggle.action = #selector(controlChanged)
        let toggles = NSStackView(views: [notifySuccessToggle, notifyFailureToggle])
        toggles.orientation = .horizontal
        toggles.spacing = 16
        card.content.addArrangedSubview(toggles)

        heartbeatToggle.target = self
        heartbeatToggle.action = #selector(controlChanged)
        card.content.addArrangedSubview(heartbeatToggle)

        configureNumberField(heartbeatIntervalField, value: config.heartbeatIntervalSeconds)
        card.content.addArrangedSubview(formGrid([
            ("心跳间隔（秒）", heartbeatIntervalField),
        ]))

        webhookTestButton.target = self
        webhookTestButton.action = #selector(testWebhook)
        card.content.addArrangedSubview(webhookTestButton)

        webhookResultLabel.font = Theme.caption()
        webhookResultLabel.maximumNumberOfLines = 0
        webhookResultLabel.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        card.content.addArrangedSubview(webhookResultLabel)

        card.content.addArrangedSubview(hint("通知格式：标题 / 时间 / 主机 / 原因 / 结果 / 详情，末尾带分隔线，方便在群里按条阅读。断网期间通知会进入本地队列，网络恢复后自动补发。"))
        card.content.addArrangedSubview(fieldExplanation("心跳通知",
            "开启后，只要网络正常，每隔「心跳间隔」就发一条「守护进程仍在运行」的通知，用来确认守护没有悄悄退出。"
            + "默认 7200 秒（2 小时）。它借用正常的探测节奏，不额外开定时器，所以实际间隔可能比设定值多出一个检查间隔。"
            + "断网期间不发；网络恢复后从恢复那一刻重新计时，不会紧接着恢复通知再发一条。"))
        return card
    }

    // MARK: - Helpers

    private func header(_ text: String) -> NSTextField {
        let field = Theme.sectionHeader(text)
        field.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        return field
    }

    private func hint(_ text: String) -> NSTextField {
        let field = Theme.hint(text)
        field.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        return field
    }

    private func pin(_ field: NSView, width: CGFloat = 300) {
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func formGrid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [Theme.formLabel($0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    private func configureNumberField(_ field: NSTextField, value: Int) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        field.formatter = formatter
        field.stringValue = String(value)
        field.delegate = self
        pin(field, width: 120)
    }

    // MARK: - Refresh

    /// Called by the settings window every time this page is shown.
    ///
    /// Must NEVER overwrite the fields from `service.config` — that would throw
    /// away text the user typed but has not committed yet (a text field only
    /// reports back on Return / focus loss, so switching pages mid-edit used to
    /// wipe the half-typed SSID). The page is the single source of truth for its
    /// own fields; only the live status label and the installed-item popups are
    /// refreshed here.
    func refresh() {
        // Flush anything still being edited before the page is hidden, so a
        // pending edit is saved rather than silently dropped.
        view.window?.makeFirstResponder(nil)
        refreshStatus()
        loadAppList()
    }

    /// One-time population from the persisted config, run after `build()`.
    private func refreshAll() {
        config = service.config
        enabledToggle.state = config.enabled ? .on : .off
        ssidField.stringValue = config.backupSSID
        passwordField.stringValue = KeychainStore.loadWiFiPassword(ssid: config.backupSSID) ?? ""
        passwordOwnerSSID = config.backupSSID
        interfaceField.stringValue = config.wifiInterface
        intervalField.stringValue = String(config.checkIntervalSeconds)
        outageField.stringValue = String(config.outageThresholdSeconds)
        cooldownField.stringValue = String(config.switchCooldownSeconds)
        overseasURLField.stringValue = config.overseasProbeURL
        domesticURLField.stringValue = config.domesticProbeURL
        vpnToggle.state = config.vpnTestEnabled ? .on : .off
        vpnPathField.stringValue = config.vpnAppPath
        vpnGraceField.stringValue = String(config.vpnGraceSeconds)
        appToggle.state = config.launchAppEnabled ? .on : .off
        webhookToggle.state = config.webhookEnabled ? .on : .off
        webhookField.stringValue = config.webhookURL
        notifySuccessToggle.state = config.notifyOnSuccess ? .on : .off
        notifyFailureToggle.state = config.notifyOnFailure ? .on : .off
        heartbeatToggle.state = config.heartbeatEnabled ? .on : .off
        heartbeatIntervalField.stringValue = String(config.heartbeatIntervalSeconds)
        loadAppList()
        refreshStatus()
    }

    @objc private func statusChanged() {
        refreshStatus()
    }

    private func refreshStatus() {
        let phase = service.phase
        statusLabel.stringValue = statusText(phase)
        statusLabel.textColor = statusColor(phase)
    }

    private func statusText(_ phase: NetWatchPhase) -> String {
        var lines = [phase.title]
        if let lastCheck = service.lastCheck {
            lines.append("上次检查：\(Self.timeFormatter.string(from: lastCheck))")
        }
        if let lastSwitch = service.lastSwitch {
            lines.append("上次切换：\(Self.timeFormatter.string(from: lastSwitch))")
        }
        if let lastRecovery = service.lastRecovery {
            lines.append("上次恢复：\(Self.timeFormatter.string(from: lastRecovery))")
        }
        if let lastHeartbeat = service.lastHeartbeatSent {
            lines.append("上次心跳：\(Self.timeFormatter.string(from: lastHeartbeat))")
        }
        if let error = service.lastError, !error.isEmpty {
            lines.append("最近错误：\(error)")
        }
        if !service.lastProbeDetail.isEmpty {
            lines.append("探测：\(service.lastProbeDetail)")
        }
        return lines.joined(separator: "\n")
    }

    private func statusColor(_ phase: NetWatchPhase) -> NSColor {
        switch phase {
        case .healthy: return .systemGreen
        case .disabled: return .secondaryLabelColor
        case .failed: return .systemRed
        default: return .systemOrange
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private func loadAppList() {
        let wanted = (appPopup.selectedItem?.representedObject as? String) ?? config.launchAppPath
        Task { [weak self] in
            let apps = await Task.detached { AppIndex.shared.apps() }.value
            guard let self else { return }
            self.appPopup.removeAllItems()
            for app in apps {
                self.appPopup.addItem(withTitle: app.name)
                self.appPopup.lastItem?.representedObject = app.url.path
            }
            // Same rule as the VPN list: keep a saved App that is no longer
            // installed (unplugged volume, moved bundle) instead of forgetting it.
            if !wanted.isEmpty, !apps.contains(where: { $0.url.path == wanted }) {
                let name = (wanted as NSString).lastPathComponent
                    .replacingOccurrences(of: ".app", with: "")
                self.appPopup.addItem(withTitle: "\(name)（未找到）")
                self.appPopup.lastItem?.representedObject = wanted
            }
            if !wanted.isEmpty {
                let index = self.appPopup.itemArray.firstIndex {
                    ($0.representedObject as? String) == wanted
                }
                if let index { self.appPopup.selectItem(at: index) }
            }
        }
    }

    // MARK: - Actions

    @objc private func controlChanged() {
        saveConfig()
    }

    /// Text fields only report on Return / focus loss, so an edit followed by
    /// closing the window or quitting the app would be lost. Free-text fields
    /// therefore save on every keystroke (idempotent and cheap — JSON into
    /// UserDefaults).
    ///
    /// Number fields are excluded on purpose: saving mid-typing would rewrite
    /// the field on a transient empty value and fight the user's cursor.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              !numberFields.contains(where: { $0 === field }) else { return }
        saveConfig()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        saveConfig()
    }

    /// Called by the settings window right before it closes and by the app on
    /// quit, so a value typed into a field that never resigned first responder
    /// is still persisted.
    func commitPendingEdits() {
        view.window?.makeFirstResponder(nil)
        saveConfig()
    }

    /// Persists every field. Values are coerced rather than dropped: an empty
    /// number field falls back to the previous value (never 0), and a popup with
    /// no selection keeps the stored path instead of clearing it.
    private func saveConfig() {
        var newConfig = config
        newConfig.enabled = enabledToggle.state == .on
        newConfig.backupSSID = ssidField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.wifiInterface = interfaceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.checkIntervalSeconds = positiveInt(intervalField, fallback: config.checkIntervalSeconds)
        newConfig.outageThresholdSeconds = positiveInt(outageField, fallback: config.outageThresholdSeconds)
        newConfig.switchCooldownSeconds = positiveInt(cooldownField, fallback: config.switchCooldownSeconds)
        newConfig.overseasProbeURL = overseasURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.domesticProbeURL = domesticURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.vpnTestEnabled = vpnToggle.state == .on
        newConfig.vpnAppPath = vpnPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.vpnGraceSeconds = positiveInt(vpnGraceField, fallback: config.vpnGraceSeconds)
        newConfig.launchAppEnabled = appToggle.state == .on
        // A popup whose list could not be loaded (no Apps found, or the chosen
        // App was deleted) has no selection — keep the stored path so reopening
        // the page restores it instead of forgetting the choice.
        if let path = appPopup.selectedItem?.representedObject as? String, !path.isEmpty {
            newConfig.launchAppPath = path
        }
        newConfig.webhookEnabled = webhookToggle.state == .on
        newConfig.webhookURL = webhookField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.notifyOnSuccess = notifySuccessToggle.state == .on
        newConfig.notifyOnFailure = notifyFailureToggle.state == .on
        newConfig.heartbeatEnabled = heartbeatToggle.state == .on
        newConfig.heartbeatIntervalSeconds = positiveInt(heartbeatIntervalField, fallback: config.heartbeatIntervalSeconds)

        // Password bookkeeping: only write the key when the password still
        // belongs to the SSID in the field. Editing the SSID invalidates it, and
        // writing an old password under a new SSID would corrupt that network.
        let typedPassword = passwordField.stringValue
        if !newConfig.backupSSID.isEmpty {
            if passwordOwnerSSID == newConfig.backupSSID {
                if !typedPassword.isEmpty {
                    KeychainStore.saveWiFiPassword(typedPassword, ssid: newConfig.backupSSID)
                }
            } else {
                // SSID changed: the typed password belongs to the NEW name.
                if !typedPassword.isEmpty {
                    KeychainStore.saveWiFiPassword(typedPassword, ssid: newConfig.backupSSID)
                }
                passwordOwnerSSID = newConfig.backupSSID
            }
        }

        config = newConfig
        service.updateConfig(newConfig)
    }

    /// A cleared or invalid number field keeps the previous value instead of
    /// collapsing to zero (which `sanitized()` would then clamp to its minimum).
    private func positiveInt(_ field: NSTextField, fallback: Int) -> Int {
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let value = Int(raw), value > 0 else {
            field.stringValue = String(fallback)
            return fallback
        }
        return value
    }

    @objc private func checkNow() {
        checkButton.isEnabled = false
        checkButton.title = "检查中…"
        service.checkNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.checkButton.isEnabled = true
            self?.checkButton.title = "立即检查"
        }
    }

    @objc private func switchNow() {
        let alert = NSAlert()
        alert.messageText = "立即切换到备用网络？"
        alert.informativeText = "当前网络会被断开，并尝试连接「\(config.backupSSID)」。"
        alert.addButton(withTitle: "切换")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        service.switchNow()
    }

    @objc private func checkWiFi() {
        let interface = config.wifiInterface.isEmpty
            ? NetWatchProbe.detectWiFiInterface()
            : config.wifiInterface
        wifiStatusLabel.stringValue = "检测中…"
        Task { [weak self] in
            let ssid = await Task.detached {
                NetWatchProbe.currentWiFiSSID(interface: interface)
            }.value
            guard let self else { return }
            if let ssid {
                self.wifiStatusLabel.stringValue = "当前 Wi-Fi：\(ssid)"
            } else {
                self.wifiStatusLabel.stringValue = "当前未连接任何 Wi-Fi（网卡 \(interface)）"
            }
        }
    }

    @objc private func chooseVPNPath() {
        chooseAppPath { [weak self] path in
            guard let self else { return }
            self.vpnPathField.stringValue = path
            self.saveConfig()
        }
    }

    @objc private func chooseApp() {
        chooseAppPath { [weak self] path in
            guard let self else { return }
            self.appPopup.addItem(withTitle: (path as NSString).lastPathComponent)
            self.appPopup.lastItem?.representedObject = path
            self.appPopup.selectItem(at: self.appPopup.numberOfItems - 1)
            self.saveConfig()
        }
    }

    private func chooseAppPath(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        completion(url.path)
    }

    @objc private func testVPN() {
        vpnTestButton.isEnabled = false
        vpnTestButton.title = "测试中…"
        Task { [weak self] in
            let ok = await self?.service.testVPNNow() ?? false
            guard let self else { return }
            self.vpnTestButton.isEnabled = true
            self.vpnTestButton.title = "立即测试 VPN"
            let alert = NSAlert()
            alert.messageText = ok ? "VPN 已连接" : "VPN 连接失败"
            alert.informativeText = ok ? "隧道已建立。" : "请检查 VPN 服务名、App 路径与登录状态。"
            alert.runModal()
        }
    }

    @objc private func testWebhook() {
        webhookTestButton.isEnabled = false
        webhookResultLabel.stringValue = "发送中…"
        webhookResultLabel.textColor = .secondaryLabelColor
        Task { [weak self] in
            let ok = await self?.service.sendTestWebhook() ?? false
            guard let self else { return }
            self.webhookTestButton.isEnabled = true
            self.webhookResultLabel.stringValue = ok ? "已发送，请检查频道。" : "发送失败，请检查 URL 与网络。"
            self.webhookResultLabel.textColor = ok ? .systemGreen : .systemRed
        }
    }
}
