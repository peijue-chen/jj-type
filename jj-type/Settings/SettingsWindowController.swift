//
//  SettingsWindowController.swift
//  jj-type
//
//  Settings UI in the macOS System Settings shape: a translucent sidebar
//  (tinted icon tiles + section names) picks one of seven card-based pages —
//  通用 / AI 服务 / 快捷键 / 快捷启动 / 终端 / 截图 / 划词动作. Every page is a
//  stack of rounded grouped cards (Theme.card()); the window auto-fits the
//  visible page. A shared footer shows the running version on every page.
//

import AppKit
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    private var store: SettingsStore!
    private let aiClient = AIClient()

    // MARK: - Page catalog

    private struct PageSpec {
        let title: String
        let subtitle: String
        let symbol: String
        let colors: [NSColor]
    }

    private let specs: [PageSpec] = [
        PageSpec(title: "通用", subtitle: "开机自启、日志与系统集成",
                 symbol: "gearshape.fill",
                 colors: [NSColor(red: 0.36, green: 0.40, blue: 0.47, alpha: 1),
                          NSColor(red: 0.55, green: 0.60, blue: 0.68, alpha: 1)]),
        PageSpec(title: "AI 服务", subtitle: "OpenAI 兼容的服务商与密钥管理",
                 symbol: "sparkles",
                 colors: [NSColor(red: 0.42, green: 0.20, blue: 0.90, alpha: 1),
                          NSColor(red: 0.62, green: 0.35, blue: 0.96, alpha: 1)]),
        PageSpec(title: "快捷键", subtitle: "各功能的全局组合键",
                 symbol: "keyboard",
                 colors: [NSColor(red: 0.93, green: 0.42, blue: 0.07, alpha: 1),
                          NSColor(red: 0.98, green: 0.62, blue: 0.24, alpha: 1)]),
        PageSpec(title: "快捷启动", subtitle: "一键打开 App、文件夹、文件与网址",
                 symbol: "rocket",
                 colors: [NSColor(red: 0.16, green: 0.45, blue: 0.94, alpha: 1),
                          NSColor(red: 0.33, green: 0.64, blue: 0.97, alpha: 1)]),
        PageSpec(title: "终端", subtitle: "Finder 工具栏打开终端（go2shell 风格）",
                 symbol: "terminal.fill",
                 colors: [NSColor(red: 0.02, green: 0.62, blue: 0.45, alpha: 1),
                          NSColor(red: 0.15, green: 0.78, blue: 0.58, alpha: 1)]),
        PageSpec(title: "截图", subtitle: "截图输出目录与图片格式",
                 symbol: "camera.viewfinder",
                 colors: [NSColor(red: 0.88, green: 0.20, blue: 0.52, alpha: 1),
                          NSColor(red: 0.95, green: 0.42, blue: 0.70, alpha: 1)]),
        PageSpec(title: "划词动作", subtitle: "选中文字后的动作条与 AI 快捷动作",
                 symbol: "textformat",
                 colors: [NSColor(red: 0.05, green: 0.62, blue: 0.58, alpha: 1),
                          NSColor(red: 0.14, green: 0.80, blue: 0.74, alpha: 1)]),
        PageSpec(title: "输入法", subtitle: "保持第三方输入法不被系统切走",
                 symbol: "keyboard.badge.ellipsis",
                 colors: [NSColor(red: 0.20, green: 0.62, blue: 0.52, alpha: 1),
                          NSColor(red: 0.42, green: 0.82, blue: 0.70, alpha: 1)]),
        PageSpec(title: "网络守护", subtitle: "断网自动切换备用网络并恢复 VPN",
                 symbol: "wifi",
                 colors: [NSColor(red: 0.10, green: 0.55, blue: 0.72, alpha: 1),
                          NSColor(red: 0.20, green: 0.72, blue: 0.80, alpha: 1)]),
    ]

    // MARK: - Chrome

    private let sidebar = NSVisualEffectView()
    private var sidebarRows: [SettingsSidebarRowView] = []
    /// Scrollable sidebar list: the rows are laid out by frame inside this
    /// flipped container (see `buildChrome`).
    private let sidebarScroll = LayoutReportingScrollView()
    private let sidebarRowsContainer = FlippedContainerView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let pageContainer = NSView()
    /// Version footer: shared by every page so the running build is always one
    /// glance away (three-part version, straight from the bundle).
    private let versionLabel = NSTextField(labelWithString: "")

    private var pages: [NSView] = []
    private weak var currentPage: NSView?
    private var pageConstraints: [NSLayoutConstraint] = []
    private var netWatchPage: NetWatchSettingsPage?

    /// 236 pt leaves room for a four-character CJK title (网络守护) plus its
    /// 22 pt icon tile and the row's inner padding — at 208 pt the last row was
    /// visually flush against the sidebar edge.
    private static let sidebarWidth: CGFloat = 236
    private static let contentWidth: CGFloat = 540
    private static let contentMargin: CGFloat = 24
    private static var minWindowWidth: CGFloat { sidebarWidth + contentWidth + contentMargin * 2 }
    /// Width available to a card's content (cards span the full page width).
    private static var cardContentWidth: CGFloat { contentWidth - Theme.cardPadding * 2 }
    /// Vertical space the sidebar uses ABOVE and BELOW its scrolling row list
    /// (identity block + separator + margins). Used to size the window so the
    /// page list is never clipped.
    private static let sidebarChromeHeight: CGFloat = 40 + 34 + 14 + 1 + 8 + 8

    // MARK: - Provider page

    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let saveButton = Theme.primaryButton("保存更改")
    private let testButton = Theme.button("测试连接", symbol: "bolt.horizontal")
    private let testResultLabel = NSTextField(labelWithString: "")
    private let activeButton = NSButton(checkboxWithTitle: "设为当前使用", target: nil, action: nil)
    private var editingProviderId: UUID?
    /// Edit-form card — appears on 新建 / row selection, hides on empty selection.
    private let providerFormContainer = Theme.card()

    // MARK: - Hotkey page

    private var translateRecorder: HotkeyRecorderView?
    private var correctRecorder: HotkeyRecorderView?
    private var captureRecorder: HotkeyRecorderView?
    private var launcherRecorder: HotkeyRecorderView?
    private var clipboardRecorder: HotkeyRecorderView?
    private var colorPickerRecorder: HotkeyRecorderView?
    private var qrCodeRecorder: HotkeyRecorderView?
    private var devToolRecorder: HotkeyRecorderView?
    private var selectionBarRecorder: HotkeyRecorderView?

    // MARK: - Launch page

    private let launchTable = NSTableView()
    private let launchNameField = NSTextField()
    private let launchKindPopup = NSPopUpButton()
    private let launchTargetField = NSTextField()
    private let launchChooseButton = Theme.button("选择…", symbol: "folder")
    private let launchSaveButton = Theme.primaryButton("保存更改")
    private var launchRecorder: HotkeyRecorderView?
    private var editingLaunchId: UUID?
    /// The launch-page hint quotes the current launcher shortcut, so it has to
    /// be rewritten when that binding changes.
    private var launchHintLabel: NSTextField?
    private let launchFormContainer = Theme.card()

    // MARK: - Terminal page

    private let terminalPopup = NSPopUpButton()
    /// Kept so the installed-state refresh can tell which page is the tab.
    private weak var terminalPage: NSStackView?

    // MARK: - Capture page

    private let captureDirectoryLabel = NSTextField(labelWithString: "")
    private let captureFormatPopup = NSPopUpButton()

    // MARK: - Tools page (划词动作)

    /// Item 0 of the popup is always "new action"; higher indices map to
    /// store.aiActions.
    private let aiActionPopup = NSPopUpButton()
    private let aiActionNameField = NSTextField()
    private let aiActionPromptTextView = NSTextView()
    private var editingAIActionId: UUID?
    private let aiActionFormContainer = Theme.card()
    private let aiActionDeleteButton = Theme.button("删除", symbol: "trash")
    /// The tools-page hint quotes the current selection-bar shortcut.
    private var selectionBarHintLabel: NSTextField?

    // MARK: - Input source page (保持输入法)

    private var inputSourceKeeperToggle: NSButton?
    private var inputSourceKeeperTargetPopup: NSPopUpButton?
    private var inputSourceKeeperModePopup: NSPopUpButton?
    private var inputSourceKeeperStatusLabel: NSTextField?
    private var inputSourceKeeperCurrentLabel: NSTextField?
    private weak var inputSourcePage: NSStackView?
    /// IDs backing `inputSourceKeeperTargetPopup`, in the same order as its
    /// items. `nil` entry = "auto" (Sogou fallback).
    private var inputSourceTargetIDs: [String?] = []
    /// Signature of the last rendered source list, used to skip rebuilding the
    /// popup when nothing changed.
    private var inputSourceTargetSignature: String = ""

    // MARK: - General page (开机自启)

    /// Kept so page switches / window re-activation can re-read the system
    /// login-item state (the user may have changed it in System Settings).
    private weak var generalPage: NSStackView?
    private var launchAtLoginToggle: NSButton?
    private var launchAtLoginStatusLabel: NSTextField?
    private var launchAtLoginSettingsButton: NSButton?
    /// Last register/unregister failure, shown in red until the next refresh.
    private var launchAtLoginError: String?

    // MARK: - Init

    convenience init(store: SettingsStore) {
        // No fixed final frame — the content view is fully constraint-driven and
        // the window auto-sizes to its fitting size, so trailing rows can never
        // be clipped.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.minWindowWidth, height: 640))
        content.translatesAutoresizingMaskIntoConstraints = false
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentViewController = NSViewController()
        window.contentViewController?.view = content
        self.store = store
        buildChrome(in: content)
        let netWatch = NetWatchSettingsPage(service: NetWatchService.shared)
        netWatchPage = netWatch
        pages = [makeGeneralPage(), makeProvidersPage(), makeHotkeyPage(),
                 makeLaunchPage(), makeTerminalPage(), makeCapturePage(),
                 makeToolsPage(), makeInputSourcePage(), netWatch.view]
        reloadTable()
        reloadForm()
        reloadLaunchTable()
        reloadLaunchForm()
        // 通用 is the first sidebar row, but AI 服务 stays the landing page
        // (first-run setup lives there) — look it up by title so inserting a
        // page never silently changes the default.
        if let index = specs.firstIndex(where: { $0.title == "AI 服务" }) {
            selectPage(index)
        }
        // Returning from 系统设置 → 登录项 must re-read the real state: the
        // user may have just approved (or switched off) the login item.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: window)
        // Persist pending edits when the window is dismissed, so a field edited
        // without Return/focus-loss is not thrown away.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window)
        // Constraints were added AFTER the contentViewController assignment, so
        // the window kept the content view's initial frame — snap it to the real
        // fitting size of the visible page now that layout is fully defined.
        resizeWindowToFit()
    }

    // MARK: - Chrome (sidebar + page frame)

    private func buildChrome(in view: NSView) {
        // -- Sidebar (translucent, blends with the desktop) ------------------
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)

        // App identity block sits under the (transparent) titlebar.
        let identityTile = IconTileView(symbol: "textformat", side: 30,
                                        colors: [NSColor(red: 0.29, green: 0.33, blue: 0.94, alpha: 1),
                                                 NSColor(red: 0.58, green: 0.33, blue: 0.96, alpha: 1)])
        let identityTitle = NSTextField(labelWithString: "JJType")
        identityTitle.font = .systemFont(ofSize: 14, weight: .bold)
        let identitySubtitle = NSTextField(labelWithString: "菜单栏效率工具")
        identitySubtitle.font = .systemFont(ofSize: 10)
        identitySubtitle.textColor = .tertiaryLabelColor
        let identityText = NSStackView(views: [identityTitle, identitySubtitle])
        identityText.orientation = .vertical
        identityText.alignment = .leading
        identityText.spacing = 0
        let identityRow = NSStackView(views: [identityTile, identityText])
        identityRow.spacing = 10
        identityRow.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(identityRow)

        let sidebarSeparator = Theme.separator()
        sidebar.addSubview(sidebarSeparator)

        // The row list scrolls: the window height follows the CONTENT page, so a
        // short page (or a small screen) would otherwise clip the last entries —
        // which is exactly how 网络守护 ended up half cut off.
        //
        // The rows live in a plain flipped container instead of the stack view
        // being the document view directly: a scroll view does not derive its
        // document height from Auto Layout constraints, so a constrained stack
        // stays at its fitting size and never scrolls. Frames are laid out by
        // hand here, and `viewDidLayout` re-syncs the width on every resize.
        sidebarScroll.drawsBackground = false
        // Toggled in `syncSidebarRowWidths`: shown only while the rows overflow,
        // so a short window is scrollable without a permanent gutter on a tall one.
        sidebarScroll.hasVerticalScroller = false
        sidebarScroll.autohidesScrollers = false
        sidebarScroll.borderType = .noBorder
        // Overlay: the knob only appears while scrolling and never steals width
        // from the rows. The legacy gutter rendered a heavy dark rail on the
        // translucent sidebar.
        sidebarScroll.scrollerStyle = .overlay
        sidebarScroll.verticalScrollElasticity = .allowed
        sidebarScroll.horizontalScrollElasticity = .none
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebarRowsContainer
        sidebar.addSubview(sidebarScroll)

        // Bottom padding so the last row is never flush against the window edge
        // (it read as "cut off" when the list ended exactly at the border).
        var y: CGFloat = 0
        for (index, spec) in specs.enumerated() {
            let row = SettingsSidebarRowView(title: spec.title, symbol: spec.symbol,
                                             colors: spec.colors) { [weak self] in
                self?.selectPage(index)
            }
            row.translatesAutoresizingMaskIntoConstraints = true
            row.frame = NSRect(x: 0, y: y, width: Self.sidebarWidth - 24,
                               height: SettingsSidebarRowView.rowHeight)
            sidebarRows.append(row)
            sidebarRowsContainer.addSubview(row)
            y += SettingsSidebarRowView.rowHeight + 2
        }
        sidebarRowsContainer.frame = NSRect(x: 0, y: 0,
                                            width: Self.sidebarWidth - 24,
                                            height: max(y - 2, 1) + 10)
        // The scroll view only learns its clip width after the first layout
        // pass, so the rows are re-widened there instead of at build time.
        sidebarScroll.onLayout = { [weak self] in
            self?.syncSidebarRowWidths()
        }

        // -- Content column ---------------------------------------------------
        titleLabel.font = Theme.pageTitle()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = Theme.body()
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.translatesAutoresizingMaskIntoConstraints = false

        versionLabel.stringValue = Self.versionText
        versionLabel.font = Theme.caption()
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .right
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(pageContainer)
        view.addSubview(versionLabel)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            identityRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            identityRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            sidebarSeparator.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            sidebarSeparator.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            sidebarSeparator.topAnchor.constraint(equalTo: identityRow.bottomAnchor, constant: 14),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarSeparator.bottomAnchor, constant: 8),
            // Bottom-pinned so the scroller runs to the window edge and the list
            // can never be clipped by a short window.
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),

            titleLabel.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor,
                                                constant: Self.contentMargin),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth),

            pageContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor,
                                                   constant: Self.contentMargin),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                    constant: -Self.contentMargin),
            // Footer sits below the page and is part of the fitting size, so the
            // height recalculation on tab switch keeps it pinned to the bottom.
            pageContainer.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            pageContainer.bottomAnchor.constraint(equalTo: versionLabel.topAnchor, constant: -8),
            versionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor,
                                                   constant: -Self.contentMargin),
            versionLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Page helpers

    /// A page is a vertical stack of cards; the window height derives from its
    /// fitting size, so a new card can never be clipped.
    private func makePage(_ cards: [CardView]) -> NSStackView {
        let stack = NSStackView(views: [])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        for card in cards {
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }
        return stack
    }

    /// Wrapping labels need an explicit width to wrap inside a leading stack.
    private func makeHint(_ text: String) -> NSTextField {
        let hint = Theme.hint(text)
        hint.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        return hint
    }

    private func makeSectionHeader(_ text: String) -> NSTextField {
        let field = Theme.sectionHeader(text)
        field.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        return field
    }

    /// Borderless rounded list used by both list pages, sized to the card width.
    private func makeListScrollView(for table: NSTableView, rows: Int) -> NSScrollView {
        let scroll = NSScrollView()
        table.headerView = nil
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.rowHeight = 44
        table.intercellSpacing = .zero
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: CGFloat(rows) * table.rowHeight),
            scroll.widthAnchor.constraint(equalToConstant: Self.cardContentWidth),
        ])
        return scroll
    }

    /// Trailing-label + control grid used by every edit form.
    private func makeFormGrid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [Theme.formLabel($0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    private func pinFieldWidth(_ field: NSView, width: CGFloat = 300) {
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    // MARK: - Page 0: 通用 (launch at login)

    private func makeGeneralPage() -> NSStackView {
        let toggle = NSButton(checkboxWithTitle: "开机时自动启动 JJType",
                              target: self, action: #selector(launchAtLoginToggled(_:)))
        launchAtLoginToggle = toggle

        // Wrapping label with a fixed width: a register() failure surfaces the
        // raw SMAppService error, which is long enough to overflow the card if
        // this were a single-line label. Same pattern as makeHint().
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = Theme.caption()
        status.maximumNumberOfLines = 0
        status.lineBreakMode = .byWordWrapping
        status.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        launchAtLoginStatusLabel = status

        let settingsButton = Theme.button("打开登录项设置", symbol: "arrow.up.forward.app")
        settingsButton.target = self
        settingsButton.action = #selector(openLoginItemsSettings)
        settingsButton.isHidden = true
        launchAtLoginSettingsButton = settingsButton

        let card = Theme.card()
        card.content.addArrangedSubview(makeSectionHeader("启动"))
        card.content.addArrangedSubview(toggle)
        card.content.addArrangedSubview(status)
        card.content.addArrangedSubview(settingsButton)
        card.content.addArrangedSubview(
            makeHint("开启后 JJType 会随 macOS 登录自动运行，条目可在 系统设置 → 通用 → 登录项 中查看或关闭。"))
        if !LaunchAtLoginService.isInApplicationsFolder {
            card.content.addArrangedSubview(
                makeHint("当前运行的 JJType 不在「应用程序」文件夹，登录项会指向现在这个位置；"
                         + "建议先把它拖进「应用程序」再开启。"))
        }

        // Diagnostics that are otherwise invisible in a release build (its
        // NSLog does not reach the unified log): the watchdog, AI requests and
        // the Finder-terminal toolbar all append to ~/Library/Logs/JJType.
        let logsButton = Theme.button("打开日志文件夹", symbol: "folder")
        logsButton.target = self
        logsButton.action = #selector(openLogsFolder)
        logsButton.toolTip = "在 Finder 中打开 \(DiagnosticLog.logURL.deletingLastPathComponent().path)"

        let logsCard = Theme.card()
        logsCard.content.addArrangedSubview(makeSectionHeader("日志"))
        logsCard.content.addArrangedSubview(logsButton)
        logsCard.content.addArrangedSubview(makeHint(
            "诊断日志都在 ~/Library/Logs/JJType：netwatch.log（网络守护）、ai.log（AI 请求）、finder-terminal.log（Finder 终端）。"))

        let page = makePage([card, logsCard])
        generalPage = page
        refreshLaunchAtLoginState(refit: false)
        return page
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let wanted = sender.state == .on
        launchAtLoginError = nil
        // A requiresApproval item can only be re-enabled by the user in
        // System Settings — register() would just fail again, so send them
        // straight to the pane instead of showing a bogus error.
        if wanted, LaunchAtLoginService.state == .requiresApproval {
            LaunchAtLoginService.openSystemSettings()
            refreshLaunchAtLoginState()
            return
        }
        do {
            try LaunchAtLoginService.setEnabled(wanted)
        } catch {
            launchAtLoginError = "设置失败：\(error.localizedDescription)"
        }
        // The system status is the truth: a failed register leaves the box
        // unchecked, and a requiresApproval result shows the approval hint.
        refreshLaunchAtLoginState()
    }

    @objc private func openLoginItemsSettings() {
        LaunchAtLoginService.openSystemSettings()
    }

    /// Reveals `~/Library/Logs/JJType` in Finder. The directory is derived from
    /// the shared log path so it stays correct if the location ever changes.
    @objc private func openLogsFolder() {
        let directory = DiagnosticLog.logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    /// The user may have flipped the login item in System Settings while this
    /// window was in the background — re-read the state on every re-activation.
    @objc private func settingsWindowDidBecomeKey(_ notification: Notification) {
        guard currentPage === generalPage else { return }
        launchAtLoginError = nil
        refreshLaunchAtLoginState()
    }

    @objc private func settingsWindowWillClose(_ notification: Notification) {
        commitNetWatchEdits()
    }

    /// Re-reads SMAppService and repaints the checkbox / status / deep link.
    /// `refit` is false while the page is being built or switched to (the
    /// caller resizes the window itself right after).
    private func refreshLaunchAtLoginState(refit: Bool = true) {
        let state = LaunchAtLoginService.state
        launchAtLoginToggle?.state = state == .enabled ? .on : .off
        if let error = launchAtLoginError {
            launchAtLoginStatusLabel?.stringValue = error
            launchAtLoginStatusLabel?.textColor = .systemRed
        } else {
            switch state {
            case .enabled:
                launchAtLoginStatusLabel?.stringValue = "已开启"
                launchAtLoginStatusLabel?.textColor = .systemGreen
            case .notRegistered:
                launchAtLoginStatusLabel?.stringValue = "未开启"
                launchAtLoginStatusLabel?.textColor = .secondaryLabelColor
            case .requiresApproval:
                launchAtLoginStatusLabel?.stringValue = "已被系统关闭，需在「登录项」中允许"
                launchAtLoginStatusLabel?.textColor = .systemOrange
            case .unavailable:
                launchAtLoginStatusLabel?.stringValue = "当前系统不支持登录项"
                launchAtLoginStatusLabel?.textColor = .secondaryLabelColor
            }
        }
        // The deep link is the only way out of requiresApproval (and of a
        // failed registration), so it appears exactly in those two cases.
        launchAtLoginSettingsButton?.isHidden =
            !(state == .requiresApproval || launchAtLoginError != nil)
        if refit { resizeWindowToFit() }
    }

    // MARK: - Page 1: AI providers (OpenAI-compatible provider CRUD)

    private func makeProvidersPage() -> NSStackView {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        tableColumn.title = "服务"
        tableView.addTableColumn(tableColumn)
        tableView.delegate = self
        tableView.dataSource = self
        let scroll = makeListScrollView(for: tableView, rows: 3)

        let addButton = Theme.primaryButton("新建", symbol: "plus")
        addButton.target = self
        addButton.action = #selector(addProvider)
        let deleteButton = Theme.button("删除", symbol: "trash")
        deleteButton.target = self
        deleteButton.action = #selector(deleteProvider)
        let listRow = NSStackView(views: [addButton, deleteButton])
        listRow.spacing = 8

        [nameField, baseURLField, apiKeyField, modelField].forEach { pinFieldWidth($0) }
        nameField.placeholderString = "如 OpenAI / DeepSeek"
        baseURLField.placeholderString = "https://api.example.com/v1"
        apiKeyField.placeholderString = "sk-…"
        modelField.placeholderString = "gpt-4o-mini"

        let formGrid = makeFormGrid([
            ("名称", nameField),
            ("Base URL", baseURLField),
            ("API Key", apiKeyField),
            ("模型名", modelField),
        ])

        saveButton.target = self
        saveButton.action = #selector(saveProvider)
        testButton.target = self
        testButton.action = #selector(testConnection)
        let providerCancelButton = Theme.button("取消")
        providerCancelButton.target = self
        providerCancelButton.action = #selector(cancelProviderEdit)
        testResultLabel.font = Theme.caption()
        testResultLabel.lineBreakMode = .byTruncatingTail
        activeButton.target = self
        activeButton.action = #selector(toggleActive(_:))

        let actionRow = NSStackView(views: [saveButton, testButton, providerCancelButton,
                                            activeButton])
        actionRow.spacing = 12

        // The edit form starts hidden — it appears on 新建 / row selection.
        providerFormContainer.isHidden = true
        providerFormContainer.content.addArrangedSubview(makeSectionHeader("编辑服务"))
        providerFormContainer.content.addArrangedSubview(formGrid)
        providerFormContainer.content.addArrangedSubview(actionRow)
        providerFormContainer.content.addArrangedSubview(testResultLabel)

        let listCard = Theme.card()
        listCard.content.addArrangedSubview(makeSectionHeader("服务列表"))
        listCard.content.addArrangedSubview(
            makeHint("Base URL 需含 /v1；API Key 只保存在系统钥匙串，● 表示当前使用的服务。"))
        listCard.content.addArrangedSubview(scroll)
        listCard.content.addArrangedSubview(listRow)

        return makePage([listCard, providerFormContainer])
    }

    // MARK: - Page 2: global hotkey rebinding

    private func makeHotkeyPage() -> NSStackView {
        let bindings: [(label: String, hotkey: Hotkey, id: HotkeyManager.HotkeyID)] = [
            ("翻译", store.translateHotkey, .translate),
            ("纠正 + 翻译", store.correctHotkey, .correctAndTranslate),
            ("划词动作条", store.selectionBarHotkey, .selectionBar),
            ("截图", store.captureHotkey, .capture),
            ("启动器", store.launcherHotkey, .launcher),
            ("剪贴板历史", store.clipboardHotkey, .clipboardHistory),
            ("取色", store.colorPickerHotkey, .colorPicker),
            ("二维码", store.qrCodeHotkey, .qrCode),
            ("开发工具", store.devToolHotkey, .devTool),
        ]
        let card = Theme.card()
        card.content.addArrangedSubview(makeSectionHeader("功能快捷键"))
        for (index, binding) in bindings.enumerated() {
            let recorder = HotkeyRecorderView(label: binding.label, hotkey: binding.hotkey,
                                              width: Self.cardContentWidth)
            recorder.onHotkeyChanged = { [weak self] hotkey in
                self?.applyHotkey(binding.id, hotkey)
            }
            switch binding.id {
            case .translate: translateRecorder = recorder
            case .correctAndTranslate: correctRecorder = recorder
            case .capture: captureRecorder = recorder
            case .launcher: launcherRecorder = recorder
            case .clipboardHistory: clipboardRecorder = recorder
            case .colorPicker: colorPickerRecorder = recorder
            case .qrCode: qrCodeRecorder = recorder
            case .devTool: devToolRecorder = recorder
            case .selectionBar: selectionBarRecorder = recorder
            }
            if index > 0 { card.addSeparator() }
            card.content.addArrangedSubview(recorder)
        }
        card.content.addArrangedSubview(
            makeHint("点击输入框后直接按下新组合键；需包含 ⌘/⌥/⌃ 至少一个修饰键。"))
        return makePage([card])
    }

    // MARK: - Page 3: launch items

    private func makeLaunchPage() -> NSStackView {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("launch"))
        tableColumn.title = "项目"
        launchTable.addTableColumn(tableColumn)
        launchTable.delegate = self
        launchTable.dataSource = self
        let scroll = makeListScrollView(for: launchTable, rows: 3)

        let addButton = Theme.primaryButton("新建", symbol: "plus")
        addButton.target = self
        addButton.action = #selector(addLaunchItem)
        let deleteButton = Theme.button("删除", symbol: "trash")
        deleteButton.target = self
        deleteButton.action = #selector(deleteLaunchItem)
        let listRow = NSStackView(views: [addButton, deleteButton])
        listRow.spacing = 8

        launchKindPopup.addItems(withTitles: LaunchTargetKind.allCases.map(\.displayName))
        launchKindPopup.target = self
        launchKindPopup.action = #selector(launchKindChanged)
        pinFieldWidth(launchKindPopup, width: 200)
        pinFieldWidth(launchNameField)
        launchTargetField.placeholderString = "https://example.com"

        launchChooseButton.target = self
        launchChooseButton.action = #selector(chooseLaunchTarget)
        let targetRow = NSStackView(views: [launchTargetField, launchChooseButton])
        targetRow.spacing = 8
        pinFieldWidth(launchTargetField, width: 212)

        let recorder = HotkeyRecorderView(label: "快捷键", hotkey: nil, allowsClearing: true,
                                          width: 320)
        recorder.onHotkeyChanged = { [weak self] hotkey in self?.applyLaunchHotkey(hotkey) }
        recorder.onHotkeyCleared = { [weak self] in self?.applyLaunchHotkey(nil) }
        launchRecorder = recorder

        launchSaveButton.target = self
        launchSaveButton.action = #selector(saveLaunchItem)
        launchSaveButton.isEnabled = false
        let launchCancelButton = Theme.button("取消")
        launchCancelButton.target = self
        launchCancelButton.action = #selector(cancelLaunchEdit)
        let launchActionRow = NSStackView(views: [launchSaveButton, launchCancelButton])
        launchActionRow.spacing = 8

        let formGrid = makeFormGrid([
            ("名称", launchNameField),
            ("类型", launchKindPopup),
            ("目标", targetRow),
            ("快捷键", recorder),
        ])

        // The edit form starts hidden — it appears on 新建 / row selection.
        launchFormContainer.isHidden = true
        launchFormContainer.content.addArrangedSubview(makeSectionHeader("编辑项目"))
        launchFormContainer.content.addArrangedSubview(formGrid)
        launchFormContainer.content.addArrangedSubview(launchActionRow)

        let hint = makeHint(Self.launchHintText(launcherHotkey: store.launcherHotkey))
        launchHintLabel = hint

        let listCard = Theme.card()
        listCard.content.addArrangedSubview(makeSectionHeader("启动项"))
        listCard.content.addArrangedSubview(hint)
        listCard.content.addArrangedSubview(scroll)
        listCard.content.addArrangedSubview(listRow)
        listCard.content.addArrangedSubview(
            makeHint("App 按 Bundle ID 记录，移动位置后仍可用；文件夹 / 文件按绝对路径记录。快捷键留空即只用菜单打开。"))

        return makePage([listCard, launchFormContainer])
    }

    // MARK: - Page 4: Finder toolbar → terminal (go2shell-style)

    private func makeTerminalPage() -> NSStackView {
        terminalPopup.target = self
        terminalPopup.action = #selector(terminalChanged)
        pinFieldWidth(terminalPopup, width: 240)
        refreshTerminalPopup()

        let guideButton = Theme.button("自动化权限引导…", symbol: "lock.shield")
        guideButton.target = self
        guideButton.action = #selector(openAutomationGuide)

        let formGrid = makeFormGrid([
            ("首选终端", terminalPopup),
            ("权限", guideButton),
        ])

        let card = Theme.card()
        card.content.addArrangedSubview(makeSectionHeader("从 Finder 打开终端"))
        card.content.addArrangedSubview(
            makeHint("按住 ⌘ 把 JJType.app 拖到 Finder 窗口工具栏，点击图标即可在当前文件夹打开终端；选中文件时打开其所在文件夹，无窗口时打开桌面；按住 ⌥ 点击图标打开本页设置。"))
        card.content.addArrangedSubview(formGrid)
        card.content.addArrangedSubview(
            makeHint("未安装的终端会置灰；首选终端被卸载后自动回退到系统终端。首次使用需要在 系统设置 → 隐私与安全性 → 自动化 中允许 JJType 控制 Finder。"))

        let page = makePage([card])
        terminalPage = page
        return page
    }

    /// (Re)builds the popup items + selection; re-run whenever the page is
    /// shown so terminals installed while the window was cached turn enabled.
    private func refreshTerminalPopup() {
        terminalPopup.removeAllItems()
        for terminal in TerminalApp.allCases {
            let item = NSMenuItem(title: terminal.displayName, action: nil, keyEquivalent: "")
            item.representedObject = terminal.rawValue
            if !terminal.isInstalled {
                item.title = "\(terminal.displayName)（未安装）"
                item.isEnabled = false
            }
            terminalPopup.menu?.addItem(item)
        }
        selectTerminal(store.preferredTerminalRawValue.flatMap(TerminalApp.init(rawValue:))
                       ?? TerminalApp.resolved)
    }

    private func selectTerminal(_ terminal: TerminalApp) {
        for item in terminalPopup.itemArray {
            if item.representedObject as? String == terminal.rawValue {
                terminalPopup.select(item)
                return
            }
        }
    }

    private static func launchHintText(launcherHotkey: Hotkey) -> String {
        "给任意 App、文件夹、文件或网址绑定一个全局快捷键；也可以按 "
            + "\(launcherHotkey.displayText) 打开启动器，输入名字筛选后回车。"
    }

    // MARK: - Page 5: screenshot output (folder / format)

    private func makeCapturePage() -> NSStackView {
        captureDirectoryLabel.font = Theme.body()
        captureDirectoryLabel.textColor = .secondaryLabelColor
        captureDirectoryLabel.lineBreakMode = .byTruncatingMiddle
        captureDirectoryLabel.stringValue = store.captureSaveDirectory.path
        pinFieldWidth(captureDirectoryLabel, width: 210)

        let chooseButton = Theme.button("选择…", symbol: "folder")
        chooseButton.target = self
        chooseButton.action = #selector(chooseCaptureDirectory)

        captureFormatPopup.addItems(withTitles: CaptureFormat.allCases.map { $0.displayName })
        if let index = CaptureFormat.allCases.firstIndex(of: store.captureFormat) {
            captureFormatPopup.selectItem(at: index)
        }
        captureFormatPopup.target = self
        captureFormatPopup.action = #selector(captureFormatChanged)
        pinFieldWidth(captureFormatPopup, width: 200)

        let directoryRow = NSStackView(views: [captureDirectoryLabel, chooseButton])
        directoryRow.spacing = 8

        let formGrid = makeFormGrid([
            ("保存目录", directoryRow),
            ("图片格式", captureFormatPopup),
        ])

        let card = Theme.card()
        card.content.addArrangedSubview(makeSectionHeader("输出设置"))
        card.content.addArrangedSubview(formGrid)
        card.content.addArrangedSubview(
            makeHint("截图需要「屏幕录制」权限；首次授权后需重启 JJType 才会生效。"))

        return makePage([card])
    }

    // MARK: - Page 6: 划词动作 — selection bar toggle + quick actions + clipboard tools

    private func makeToolsPage() -> NSStackView {
        // -- 划词动作条开关 ------------------------------------------------
        let barToggle = NSButton(checkboxWithTitle: "划词后自动显示动作条",
                                 target: self, action: #selector(selectionBarToggled(_:)))
        barToggle.state = store.selectionBarEnabled ? .on : .off

        // 「快捷键直接翻译」: the hotkey skips the bar and translates at once.
        let directToggle = NSButton(checkboxWithTitle: "快捷键直接翻译（不显示动作条）",
                                    target: self,
                                    action: #selector(selectionBarDirectTranslateToggled(_:)))
        directToggle.state = store.selectionBarDirectTranslate ? .on : .off

        let selectionBarHint = makeHint(Self.selectionBarHintText(hotkey: store.selectionBarHotkey))
        selectionBarHintLabel = selectionBarHint

        let barCard = Theme.card()
        barCard.content.addArrangedSubview(makeSectionHeader("划词动作条"))
        barCard.content.addArrangedSubview(barToggle)
        barCard.content.addArrangedSubview(
            makeHint("在任意应用拖选文字后，鼠标下方自动出现动作条（AI 动作 / 二维码）；点击其它位置立即消失。需要辅助功能权限。检测只读取选中文字，不会改动你的剪贴板。"))
        barCard.content.addArrangedSubview(selectionBarHint)
        barCard.content.addArrangedSubview(directToggle)
        barCard.content.addArrangedSubview(
            makeHint("开启后，划词快捷键会直接翻译选中文字并弹出结果，不再先显示动作条（少点一次）。"))

        // -- AI 动作编辑表单（默认隐藏）------------------------------------
        let newActionButton = Theme.primaryButton("新建动作…", symbol: "plus")
        newActionButton.target = self
        newActionButton.action = #selector(newAIActionClicked)

        aiActionPopup.target = self
        aiActionPopup.action = #selector(aiActionPopupChanged)
        pinFieldWidth(aiActionPopup, width: 240)
        aiActionNameField.placeholderString = "动作名称（如：总结）"
        pinFieldWidth(aiActionNameField)
        aiActionPromptTextView.font = Theme.body()
        aiActionPromptTextView.isRichText = false
        aiActionPromptTextView.isEditable = true
        aiActionPromptTextView.drawsBackground = true
        refreshAIActionPopup(selectingId: nil)

        let promptScroll = NSScrollView()
        promptScroll.documentView = aiActionPromptTextView
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .noBorder
        promptScroll.drawsBackground = false
        promptScroll.wantsLayer = true
        promptScroll.layer?.cornerRadius = 6
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            promptScroll.heightAnchor.constraint(equalToConstant: 76),
            promptScroll.widthAnchor.constraint(equalToConstant: 300),
        ])

        let saveButton = Theme.primaryButton("保存", symbol: "checkmark")
        saveButton.target = self
        saveButton.action = #selector(saveAIAction)
        aiActionDeleteButton.target = self
        aiActionDeleteButton.action = #selector(deleteAIAction)
        let cancelButton = Theme.button("取消")
        cancelButton.target = self
        cancelButton.action = #selector(cancelAIAction)
        let editorRow = NSStackView(views: [saveButton, aiActionDeleteButton, cancelButton])
        editorRow.spacing = 8

        let formGrid = makeFormGrid([
            ("动作", aiActionPopup),
            ("名称", aiActionNameField),
            ("提示词", promptScroll),
        ])

        aiActionFormContainer.isHidden = true
        aiActionFormContainer.content.addArrangedSubview(makeSectionHeader("编辑动作"))
        aiActionFormContainer.content.addArrangedSubview(formGrid)
        aiActionFormContainer.content.addArrangedSubview(editorRow)

        let actionsCard = Theme.card()
        actionsCard.content.addArrangedSubview(makeSectionHeader("AI 快捷动作"))
        actionsCard.content.addArrangedSubview(newActionButton)
        actionsCard.content.addArrangedSubview(aiActionFormContainer)
        actionsCard.content.addArrangedSubview(
            makeHint("内置 翻译 / 纠正 / 润色 / 改写 与自定义动作统一在此管理；提示词用 {text} 代表选中文本。内置动作可修改提示词，不可删除；其中「翻译」固定使用与翻译窗口相同的提示词与解析流程（修改其提示词不会生效）。"))

        // -- 剪贴板历史 -----------------------------------------------------
        let clearButton = Theme.button("清空剪贴板历史", symbol: "trash")
        clearButton.target = self
        clearButton.action = #selector(clearClipboardHistory)

        let clipboardCard = Theme.card()
        clipboardCard.content.addArrangedSubview(makeSectionHeader("剪贴板历史"))
        clipboardCard.content.addArrangedSubview(clearButton)
        clipboardCard.content.addArrangedSubview(
            makeHint("剪贴板历史记录复制的文本与图片（上限 500 条，重启保留）；敏感复制自动跳过。"))

        return makePage([barCard, actionsCard, clipboardCard])
    }

    @objc private func selectionBarToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        store.selectionBarEnabled = enabled
        SelectionActionBarController.shared.setEnabled(enabled)
    }

    @objc private func selectionBarDirectTranslateToggled(_ sender: NSButton) {
        store.selectionBarDirectTranslate = sender.state == .on
    }

    @objc private func clearClipboardHistory() {
        // Destructive clear-all: same confirmation pattern as the deletes.
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "全部 \(ClipboardHistoryService.shared.entries.count) 条记录（含图片）会被删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ClipboardHistoryService.shared.clearAll()
        CaptureToast.shared.show("已清空剪贴板历史", symbol: "trash")
    }

    // MARK: - Custom AI quick actions (Tools page)

    private func refreshAIActionPopup(selectingId: UUID?) {
        aiActionPopup.removeAllItems()
        aiActionPopup.addItem(withTitle: "＋ 新建动作…")
        for action in store.aiActions {
            aiActionPopup.addItem(withTitle: action.name)
        }
        if let id = selectingId,
           let index = store.aiActions.firstIndex(where: { $0.id == id }) {
            aiActionPopup.selectItem(at: index + 1)
        } else {
            aiActionPopup.selectItem(at: 0)
        }
        syncAIActionFields()
    }

    private func syncAIActionFields() {
        let index = aiActionPopup.indexOfSelectedItem - 1
        if store.aiActions.indices.contains(index) {
            let action = store.aiActions[index]
            editingAIActionId = action.id
            aiActionNameField.stringValue = action.name
            aiActionPromptTextView.string = action.prompt
            // Built-ins are editable but never deletable.
            aiActionDeleteButton.isEnabled = !QuickActionCatalog.builtInIds.contains(action.id)
        } else {
            editingAIActionId = nil
            aiActionNameField.stringValue = ""
            aiActionPromptTextView.string = ""
            aiActionDeleteButton.isEnabled = true
        }
    }

    @objc private func newAIActionClicked() {
        aiActionPopup.selectItem(at: 0)
        syncAIActionFields()
        setForm(aiActionFormContainer, hidden: false)
        window?.makeFirstResponder(aiActionNameField)
    }

    @objc private func aiActionPopupChanged() {
        syncAIActionFields()
        setForm(aiActionFormContainer, hidden: false)
    }

    @objc private func cancelAIAction() {
        editingAIActionId = nil
        setForm(aiActionFormContainer, hidden: true)
        refreshAIActionPopup(selectingId: nil)
    }

    @objc private func saveAIAction() {
        let name = aiActionNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = aiActionPromptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else {
            showAlert("请填写动作名称和提示词", "名称与提示词都不能为空。")
            return
        }
        if let id = editingAIActionId {
            store.updateAIAction(QuickAction(id: id, name: name, prompt: prompt))
        } else {
            let action = QuickAction(id: UUID(), name: name, prompt: prompt)
            store.addAIAction(action)
            editingAIActionId = action.id
        }
        refreshAIActionPopup(selectingId: editingAIActionId)
        setForm(aiActionFormContainer, hidden: true)
    }

    @objc private func deleteAIAction() {
        guard let id = editingAIActionId,
              let action = store.aiActions.first(where: { $0.id == id }) else { return }
        // Same guard as provider deletion: a stray click must not drop a
        // configured action (its prompt is unrecoverable).
        let alert = NSAlert()
        alert.messageText = "删除「\(action.name)」？"
        alert.informativeText = "该动作的提示词会被一起删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteAIAction(id: id)
        refreshAIActionPopup(selectingId: nil)
        setForm(aiActionFormContainer, hidden: true)
    }

    // MARK: - Page 7: 输入法 — keep a third-party IME selected

    private func makeInputSourcePage() -> NSStackView {
        let toggle = NSButton(checkboxWithTitle: "保持输入法",
                              target: self, action: #selector(inputSourceKeeperToggled(_:)))
        toggle.state = store.inputSourceKeeperEnabled ? .on : .off
        inputSourceKeeperToggle = toggle

        let targetPopup = NSPopUpButton()
        targetPopup.target = self
        targetPopup.action = #selector(inputSourceKeeperTargetChanged(_:))
        pinFieldWidth(targetPopup, width: 200)
        inputSourceKeeperTargetPopup = targetPopup

        let modePopup = NSPopUpButton()
        for mode in InputSourceKeeperMode.allCases {
            modePopup.addItem(withTitle: mode.title)
        }
        modePopup.target = self
        modePopup.action = #selector(inputSourceKeeperModeChanged(_:))
        pinFieldWidth(modePopup, width: 200)
        inputSourceKeeperModePopup = modePopup

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = Theme.caption()
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 0
        status.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        inputSourceKeeperStatusLabel = status

        let current = NSTextField(wrappingLabelWithString: "")
        current.font = Theme.caption()
        current.textColor = .tertiaryLabelColor
        current.maximumNumberOfLines = 0
        current.widthAnchor.constraint(equalToConstant: Self.cardContentWidth - 2).isActive = true
        inputSourceKeeperCurrentLabel = current

        let openSettings = Theme.button("打开输入法设置", symbol: "arrow.up.forward.app")
        openSettings.target = self
        openSettings.action = #selector(openKeyboardSettings)

        let formGrid = makeFormGrid([
            ("目标输入法", targetPopup),
            ("纠正时机", modePopup),
            ("系统设置", openSettings),
        ])

        let card = Theme.card()
        card.content.addArrangedSubview(makeSectionHeader("保持输入法"))
        card.content.addArrangedSubview(toggle)
        card.content.addArrangedSubview(formGrid)
        card.content.addArrangedSubview(status)
        card.content.addArrangedSubview(current)
        card.content.addArrangedSubview(
            makeHint("macOS 会按 App 记住上次用的输入法，切走再回来常常变回 ABC。开启后 JJType 会在切换 App 时把输入法切回你选的目标。"))
        card.content.addArrangedSubview(
            makeHint("「切换 App 时纠正」不会干扰你在同一个 App 里手动切换；「始终纠正」会在任何时刻把输入法拉回目标输入法。"))
        card.content.addArrangedSubview(
            makeHint("纠正会延迟约 0.5 秒执行：立即切回会让输入法在「停用未完成」时被重新激活，导致它卡在英文模式、Shift 切不回中文。"))

        let page = makePage([card])
        inputSourcePage = page
        refreshInputSourceState()
        return page
    }

    /// Re-reads the keeper state and repaints the page. Called on page build,
    /// on page switch, and whenever the keeper reports a change.
    private func refreshInputSourceState() {
        let keeper = InputSourceKeeper.shared
        keeper.refreshStatus()

        inputSourceKeeperToggle?.state = keeper.isEnabled ? .on : .off
        if let index = InputSourceKeeperMode.allCases.firstIndex(of: keeper.mode) {
            inputSourceKeeperModePopup?.selectItem(at: index)
        }
        reloadInputSourceTargetPopup(selected: keeper.targetID)

        switch keeper.status {
        case .ready(_, let name):
            inputSourceKeeperStatusLabel?.stringValue = "✓ 已检测到 \(name)"
            inputSourceKeeperStatusLabel?.textColor = .secondaryLabelColor
        case .installedButDisabled:
            inputSourceKeeperStatusLabel?.stringValue = "! 目标输入法已安装，但系统尚未启用它。请到「系统设置 → 键盘 → 输入法」添加。"
            inputSourceKeeperStatusLabel?.textColor = .systemOrange
        case .notInstalled:
            inputSourceKeeperStatusLabel?.stringValue = "未检测到目标输入法。安装后回到本页即可启用。"
            inputSourceKeeperStatusLabel?.textColor = .secondaryLabelColor
        }

        if let current = keeper.currentSourceName {
            inputSourceKeeperCurrentLabel?.stringValue = "当前输入法：\(current)"
        } else {
            inputSourceKeeperCurrentLabel?.stringValue = ""
        }

        // The keeper is inert without a ready target — say so instead of
        // letting the checkbox look like it is doing something. An already
        // enabled keeper stays toggleable so the user can always turn it off
        // (e.g. after uninstalling the target IME).
        let ready = keeper.status.isReady
        inputSourceKeeperToggle?.isEnabled = ready || keeper.isEnabled
        inputSourceKeeperTargetPopup?.isEnabled = true
        inputSourceKeeperModePopup?.isEnabled = ready && keeper.isEnabled
    }

    /// Rebuilds the target popup from the live input-source list. Rebuilding is
    /// skipped when the list is unchanged, because replacing the menu while it
    /// is open would close it.
    private func reloadInputSourceTargetPopup(selected: String?) {
        guard let popup = inputSourceKeeperTargetPopup else { return }
        let sources = InputSourceKeeper.selectableInputMethods()

        // A stored target that is not in the IME list is either a keyboard
        // layout picked before the list was filtered, or an IME that is
        // currently uninstalled/disabled. Keep it visible so the popup matches
        // what the keeper is actually targeting.
        var extraTarget: String?
        var extraLabel: String?
        if let selected,
           !sources.contains(where: { InputSourceKeeper.isSameSource($0.id, selected) }) {
            extraTarget = selected
            let stillValid = InputSourceKeeper.selectableSources()
                .contains { InputSourceKeeper.isSameSource($0.id, selected) }
            extraLabel = stillValid ? "\(selected)（键盘布局）" : "\(selected)（不可用）"
        }

        let signature = sources.map { "\($0.id)|\($0.name)" }.joined(separator: "\n")
            + "\u{1F}" + (extraTarget ?? "")
        if signature == inputSourceTargetSignature, popup.numberOfItems > 0 {
            if let index = inputSourceTargetIDs.firstIndex(where: { $0 == selected }) {
                popup.selectItem(at: index)
            }
            return
        }
        inputSourceTargetSignature = signature

        popup.removeAllItems()
        inputSourceTargetIDs = [nil]
        popup.addItem(withTitle: "自动（搜狗）")
        for source in sources {
            inputSourceTargetIDs.append(source.id)
            popup.addItem(withTitle: source.name)
        }
        if let extraTarget, let extraLabel {
            inputSourceTargetIDs.append(extraTarget)
            popup.addItem(withTitle: extraLabel)
        }
        if let index = inputSourceTargetIDs.firstIndex(where: { $0 == selected }) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
    }

    @objc private func inputSourceKeeperToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        store.inputSourceKeeperEnabled = enabled
        InputSourceKeeper.shared.setEnabled(enabled)
        refreshInputSourceState()
    }

    @objc private func inputSourceKeeperTargetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < inputSourceTargetIDs.count else { return }
        let id = inputSourceTargetIDs[index]
        store.inputSourceKeeperTarget = id
        InputSourceKeeper.shared.setTarget(id)
        refreshInputSourceState()
    }

    @objc private func inputSourceKeeperModeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < InputSourceKeeperMode.allCases.count else { return }
        let mode = InputSourceKeeperMode.allCases[index]
        store.inputSourceKeeperMode = mode
        InputSourceKeeper.shared.setMode(mode)
        refreshInputSourceState()
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

    // MARK: - Page switching

    private func selectPage(_ index: Int) {
        guard index >= 0, index < pages.count else { return }
        titleLabel.stringValue = specs[index].title
        subtitleLabel.stringValue = specs[index].subtitle
        sidebarRows.enumerated().forEach { offset, row in row.setSelected(offset == index) }
        show(page: pages[index])
        // The window is cached for the app's lifetime, so a terminal installed
        // since the popup was first built would stay greyed — rebuild the
        // installed state every time the page is shown.
        if terminalPage != nil, pages[index] === terminalPage {
            refreshTerminalPopup()
        }
        // Same idea for the login item: the user may have changed it in
        // System Settings since the page was last shown.
        if generalPage != nil, pages[index] === generalPage {
            launchAtLoginError = nil
            refreshLaunchAtLoginState(refit: false)
        }
        // The user may have installed / enabled Sogou since the page was built.
        if inputSourcePage != nil, pages[index] === inputSourcePage {
            refreshInputSourceState()
        }
        // NetWatch: re-read the live phase and the installed VPN/app lists.
        if let netWatchPage, pages[index] === netWatchPage.view {
            netWatchPage.refresh()
        }
        resizeWindowToFit()
    }

    /// Persist any half-finished edit before the window goes away, so a value
    /// typed without pressing Return or clicking elsewhere is not lost.
    func commitPendingEdits() {
        netWatchPage?.commitPendingEdits()
    }

    private func commitNetWatchEdits() {
        commitPendingEdits()
    }

    /// ⌥-click on the Finder toolbar icon opens settings straight onto the
    /// terminal page (go2shell parity: its ⌥-click shows the terminal picker).
    func selectTerminalSection() {
        guard let index = specs.firstIndex(where: { $0.title == "终端" }) else { return }
        selectPage(index)
    }

    /// Menu entry: open settings on the 网络守护 page.
    func selectNetWatchSection() {
        guard let index = specs.firstIndex(where: { $0.title == "网络守护" }) else { return }
        selectPage(index)
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

    /// Toggles an edit-form card AND re-fits the window — the page height
    /// changes with every form show/hide, and a static window clipped the
    /// rows below (the 划词动作 取消 glitch).
    private func setForm(_ container: NSView, hidden: Bool) {
        guard container.isHidden != hidden else { return }
        container.isHidden = hidden
        resizeWindowToFit()
    }

    /// Each page has its own height: resize the window and keep its top edge in
    /// place so the title bar does not jump when switching.
    private func resizeWindowToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        // The sidebar must never be the reason the window is too short: grow to
        // fit its rows (the list still scrolls when the screen cannot hold it).
        var height = max(420, fitting.height)
        let sidebarNeeded = Self.sidebarChromeHeight + sidebarRowsContainer.frame.height
        let screenMax = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        height = max(height, min(sidebarNeeded, screenMax - 40))
        let size = NSSize(width: max(Self.minWindowWidth, fitting.width), height: height)
        let top = window.frame.maxY
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
        // The sidebar scroller only gets its real height after the resize.
        syncSidebarRowWidths()
    }

    /// Keeps the hand-laid-out sidebar rows as wide as the scroll view's clip
    /// view, and shows the scrollbar only while the list actually overflows.
    ///
    /// Runs on every layout pass instead of relying on constraints — a scroll
    /// view's document view has no Auto Layout height contract, so the rows and
    /// the document size are set by hand.
    private func syncSidebarRowWidths() {
        let clipHeight = sidebarScroll.contentView.bounds.height
        let contentHeight = sidebarRowsContainer.frame.height
        guard clipHeight > 0, contentHeight > 0 else { return }

        // A permanent scroller gutter on a short list reads as a glitch, so it
        // is only shown when it can actually scroll.
        let overflows = contentHeight > clipHeight + 0.5
        if sidebarScroll.hasVerticalScroller != overflows {
            sidebarScroll.hasVerticalScroller = overflows
        }

        let width = sidebarScroll.contentView.bounds.width
        guard width > 0 else { return }
        guard abs(sidebarRowsContainer.frame.width - width) > 0.5 else { return }
        sidebarRowsContainer.frame.size.width = width
        for row in sidebarRows {
            var frame = row.frame
            frame.size.width = width
            row.frame = frame
        }
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
            // No selection → the edit form collapses away.
            setForm(providerFormContainer, hidden: true)
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
        // A selected row opens its edit form.
        setForm(providerFormContainer, hidden: false)
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
            // No selection → the edit form collapses away.
            setForm(launchFormContainer, hidden: true)
            return
        }
        editingLaunchId = item.id
        launchNameField.stringValue = item.name
        launchKindPopup.selectItem(at: LaunchTargetKind.allCases.firstIndex(of: item.kind) ?? 0)
        launchTargetField.stringValue = item.target
        launchRecorder?.setHotkey(item.hotkey)
        launchSaveButton.isEnabled = true
        updateLaunchTargetUI()
        // An edited item opens its edit form.
        setForm(launchFormContainer, hidden: false)
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
        flashPrimaryTitle(saveButton, "已保存")
    }

    /// Temporarily re-titles a primary (accent-filled) button while keeping the
    /// white-on-accent attributed style that a plain `.title` write destroys.
    private func flashPrimaryTitle(_ button: NSButton, _ text: String) {
        let original = button.attributedTitle
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: NSColor.white])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak button] in
            button?.attributedTitle = original
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

    /// Collapses the edit form and drops the row selection (对称于 新建/选中).
    @objc private func cancelProviderEdit() {
        tableView.deselectAll(nil)
        reloadForm()
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
        case .clipboardHistory: return store.clipboardHotkey
        case .colorPicker: return store.colorPickerHotkey
        case .qrCode: return store.qrCodeHotkey
        case .devTool: return store.devToolHotkey
        case .selectionBar: return store.selectionBarHotkey
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
        case .clipboardHistory: store.clipboardHotkey = hotkey
        case .colorPicker: store.colorPickerHotkey = hotkey
        case .qrCode: store.qrCodeHotkey = hotkey
        case .devTool: store.devToolHotkey = hotkey
        case .selectionBar:
            store.selectionBarHotkey = hotkey
            selectionBarHintLabel?.stringValue = Self.selectionBarHintText(hotkey: hotkey)
        }
    }

    /// Tools-page hint quoting the current selection-bar shortcut (rewritten
    /// when the binding changes on the 快捷键 page).
    private static func selectionBarHintText(hotkey: Hotkey) -> String {
        "关闭上面的自动显示后，仍可按 \(hotkey.displayText) 手动唤起动作条；" +
            "浏览器 / Electron 等应用无法被动读取选中文本时，也用它。"
    }

    private func recorder(for id: HotkeyManager.HotkeyID) -> HotkeyRecorderView? {
        switch id {
        case .translate: return translateRecorder
        case .correctAndTranslate: return correctRecorder
        case .capture: return captureRecorder
        case .launcher: return launcherRecorder
        case .clipboardHistory: return clipboardRecorder
        case .colorPicker: return colorPickerRecorder
        case .qrCode: return qrCodeRecorder
        case .devTool: return devToolRecorder
        case .selectionBar: return selectionBarRecorder
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

    /// Stores the bundle id; the use-time resolver handles uninstalled targets.
    @objc private func terminalChanged() {
        guard let rawValue = terminalPopup.selectedItem?.representedObject as? String,
              TerminalApp(rawValue: rawValue) != nil else { return }
        store.preferredTerminalRawValue = rawValue
    }

    /// Finder-terminal flow needs the Automation grant for Finder; the guide
    /// window carries verification + the system-settings deep link.
    @objc private func openAutomationGuide() {
        AutomationGuideWindowController.shared.showIfNeeded(force: true)
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
        // Confirm like provider deletion: the binding (and its hotkey slot)
        // disappears with the row on a click that is easy to mis-hit.
        let alert = NSAlert()
        alert.messageText = "删除「\(item.name)」？"
        alert.informativeText = "该项目及其快捷键绑定会被删除，无法恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
        flashPrimaryTitle(launchSaveButton, "已保存")
    }

    /// Collapses the edit form, drops the id binding and the row selection —
    /// symmetric with 新建 / row selection opening it.
    @objc private func cancelLaunchEdit() {
        editingLaunchId = nil
        launchTable.deselectAll(nil)
        reloadLaunchForm()
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
        if store.clipboardHotkey == hotkey { return "剪贴板历史" }
        if store.colorPickerHotkey == hotkey { return "取色" }
        if store.qrCodeHotkey == hotkey { return "二维码" }
        if store.devToolHotkey == hotkey { return "开发工具" }
        if store.selectionBarHotkey == hotkey { return "划词动作条" }
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
            guard row < store.launchItems.count else { return nil }
            let item = store.launchItems[row]
            let cell = (tableView.makeView(withIdentifier: SettingsListCell.reuseIdentifier,
                                           owner: self) as? SettingsListCell)
                ?? SettingsListCell()
            let detail = item.hotkey.map { "\(item.kind.displayName) · \($0.displayText)" }
                ?? item.kind.displayName
            cell.configure(title: item.name, detail: detail,
                           symbol: Self.symbol(for: item.kind), tint: .secondaryLabelColor,
                           badge: nil)
            return cell
        }
        guard row < store.providers.count else { return nil }
        let provider = store.providers[row]
        let cell = (tableView.makeView(withIdentifier: SettingsListCell.reuseIdentifier,
                                       owner: self) as? SettingsListCell)
            ?? SettingsListCell()
        cell.configure(title: provider.name, detail: provider.model,
                       symbol: "sparkles", tint: .secondaryLabelColor,
                       badge: provider.id == store.activeProviderId ? "使用中" : nil)
        return cell
    }

    private static func symbol(for kind: LaunchTargetKind) -> String {
        switch kind {
        case .application: return "app.fill"
        case .folder: return "folder.fill"
        case .file: return "doc.fill"
        case .url: return "link"
        }
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

// MARK: - Sidebar row

/// Top-left origin container, so hand-positioned rows stack downward from y=0
/// (a plain NSView would measure y from the BOTTOM of the document view).
final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// A scroll view that reports every layout pass.
///
/// A scroll view derives its document size from the document view's FRAME, not
/// from Auto Layout, so the sidebar rows cannot be constraint-driven. They are
/// positioned by hand and re-widened from `onLayout` — the clip view width is
/// only correct once the window has been sized, which happens after the initial
/// constraint pass.
final class LayoutReportingScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// One sidebar entry: tinted icon tile + title, highlighted while selected
/// (accent-tinted rounded fill, re-resolved on appearance changes).
/// Exposes itself as an accessibility BUTTON so VoiceOver / keyboard /
/// automation can switch pages (the old segmented control was pressable —
/// a plain NSView is not, which was an a11y regression).
final class SettingsSidebarRowView: NSView {
    /// Fixed row height. The sidebar list is laid out by frame inside a
    /// scrolling container, so this must stay a constant the container can add up.
    static let rowHeight: CGFloat = 36

    private let rowTitle: String
    private let onSelect: () -> Void
    private var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(title: String, symbol: String, colors: [NSColor],
         onSelect: @escaping () -> Void) {
        self.rowTitle = title
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: Self.rowHeight))
        // Frame-based: the scrolling sidebar container positions these rows by
        // hand, so Auto Layout must not fight it over height.
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        let tile = IconTileView(symbol: symbol, side: 22, colors: colors)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        // Shrink instead of overflow: a longer page title must never run into
        // the sidebar edge, or be clipped by it.
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [tile, label])
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSelected(_ selected: Bool) {
        isSelected = selected
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onSelect()
    }

    // MARK: Accessibility (pressable sidebar entry)

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? { rowTitle }

    /// AXTitle too — `name` for UI scripting / System Events, while the label
    /// covers VoiceOver's description fallback.
    override func accessibilityTitle() -> String? { rowTitle }

    override func accessibilityValue() -> Any? { isSelected ? "已选中" : nil }

    override func accessibilityPerformPress() -> Bool {
        onSelect()
        return true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = 7
        layer?.backgroundColor = isSelected
            ? Theme.accent.withAlphaComponent(0.16).cgColor
            : nil
    }
}

// MARK: - Settings list cell

/// Two-line list row used by both list pages: secondary symbol + title +
/// caption detail + optional trailing badge ("使用中").
final class SettingsListCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("settingsListCell")

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.bodyMedium()
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = Theme.caption()
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .systemGreen
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor,
                                                constant: 8),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, detail: String, symbol: String, tint: NSColor, badge: String?) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = tint
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        badgeLabel.stringValue = badge ?? ""
        badgeLabel.isHidden = badge == nil
    }
}
