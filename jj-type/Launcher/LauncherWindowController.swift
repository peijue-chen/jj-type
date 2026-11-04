//
//  LauncherWindowController.swift
//  jj-type
//
//  Alfred-style keyboard launcher: one non-activating panel, type to filter the
//  configured launch items and every installed application, ↑/↓ to move, ⏎ to
//  open, esc (or a click outside) to dismiss. The panel never activates the app,
//  so the frontmost application keeps its focus ring and only the panel takes
//  keystrokes.
//

import AppKit

/// One row of the result list: a configured item, an app found by the index, or
/// a fallback for a query that matches nothing — "just open what I typed" when it
/// looks like a path / URL, a web search otherwise.
private enum LauncherRow {
    case item(LaunchItem)
    case app(DiscoveredApp)
    case system(SystemCommand)
    case direct(String)
    case webSearch(String)

    var title: String {
        switch self {
        case .item(let item): return item.name
        case .app(let app): return app.name
        case .system(let command): return command.title
        case .direct(let raw): return "打开「\(raw)」"
        case .webSearch(let term): return "用 Google 搜索「\(term)」"
        }
    }
}

final class LauncherWindowController: NSWindowController {
    /// The controller never opens anything itself: AppDelegate owns the single
    /// failure-reporting path.
    var onOpenItem: ((LaunchItem) -> Void)?
    var onOpenApp: ((URL) -> Void)?
    var onOpenDirect: ((String) -> Void)?
    var onOpenSystem: ((SystemCommand) -> Void)?

    private let searchField = NSTextField()
    private let searchBadge = LauncherSearchBadge(frame: .zero)
    private let searchIcon = NSImageView()
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var listHeightConstraint: NSLayoutConstraint!
    private var outsideMonitors: [Any] = []

    private var items: [LaunchItem] = []
    /// Paths already covered by a configured item, so an app never shows twice.
    private var configuredPaths: Set<String> = []
    /// Pre-lowercased search key, word initials + REAL path per app: filtering
    /// must never lower-case or standardise hundreds of URLs again on every
    /// keystroke.
    private var apps: [(app: DiscoveredApp, key: String, initials: String, path: String)] = []
    /// Icons are a bundle read (expensive). One lookup per path / item, reused by
    /// every keystroke and every reopen.
    private var fileIconCache: [String: NSImage] = [:]
    private var itemIconCache: [UUID: NSImage] = [:]
    private var rows: [LauncherRow] = []
    private var selectedIndex = -1
    /// Typing is debounced: rescoring + resorting + `reloadData` on every single
    /// keystroke is what made fast typing feel laggy.
    private var filterGeneration = 0
    private var pendingFilter: DispatchWorkItem?
    private static let filterDelay: TimeInterval = 0.06
    /// Resizing a `.behindWindow` HUD panel re-blurs the desktop behind it — by
    /// far the most expensive thing a keystroke could trigger — so the frame
    /// change is coalesced and applied once the typing settles.
    private var resizeGeneration = 0
    private var pendingResize: DispatchWorkItem?
    /// Deliberately longer than the filter debounce: a burst of keystrokes must
    /// end up as ONE resize (deleting characters grows the result count, so every
    /// step used to resize the panel).
    private static let resizeDelay: TimeInterval = 0.25
    /// Only the best matches are worth showing (and reloading) — the list shows
    /// seven rows at a time, never hundreds.
    private static let resultLimit = 60

    private static let width: CGFloat = 600
    private static let rowHeight: CGFloat = 46
    /// Beyond this the list scrolls instead of growing (a launcher that fills the
    /// screen is no longer a launcher).
    private static let maxVisibleRows = 7

    convenience init() {
        let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // Visible over full-screen apps and on whichever Space the user is in.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        self.init(window: panel)

        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        panel.contentView = content
        buildLayout(in: content)
    }

    // MARK: - Public API

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Opens the panel with a clean query. `items` is passed in so the controller
    /// stays stateless and always shows the current settings.
    func present(items: [LaunchItem]) {
        self.items = items
        // Canonical paths: an item configured by bundle id or through the
        // symlinked `/Applications/Safari.app` must still hide the index entry
        // for the same app, or it shows up twice.
        configuredPaths = Set(items.compactMap {
            $0.resolvedURL?.resolvingSymlinksInPath().standardizedFileURL.path
        })
        // A reopened launcher must reflect the current settings, so the per-item
        // icon cache is dropped (file icons stay: they are keyed by path).
        itemIconCache.removeAll()
        cancelPendingFilter()
        searchField.stringValue = ""
        // Immediate size: the panel has to be positioned with its final height.
        rebuildRows(immediateResize: true)
        positionWindow()
        guard let window else { return }
        // orderFrontRegardless, NOT makeKeyAndOrderFront: `orderFront` is ignored
        // while the app is inactive — which is exactly our case, so the panel
        // would silently never appear.
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(searchField)
        installOutsideMonitors()
        loadApplicationIndex()

        // Safety net: a non-activating panel should take keys without activating
        // the app, but if this Space/full-screen state refuses, the panel would
        // be visible and deaf. Give AppKit one runloop turn, then fall back to
        // activating so typing always works.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  window.isVisible, !window.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            window.makeFirstResponder(self.searchField)
        }
    }

    /// Single dismissal path (esc / outside click / after opening a row).
    func dismiss() {
        cancelPendingFilter()
        cancelPendingResize()
        removeOutsideMonitors()
        window?.orderOut(nil)
    }

    // MARK: - Application index

    /// Refreshed on every open (the index itself caches for a few minutes), so an
    /// app installed while JJType runs appears without a relaunch. The first ⌥O
    /// shows configured items right away and swaps in the full app list a moment
    /// later; an unchanged index never triggers a second rebuild.
    private func loadApplicationIndex() {
        Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                AppIndex.shared.apps()
            }.value
            guard let self else { return }
            let entries = scanned.map {
                (app: $0, key: $0.name.lowercased(), initials: Self.initials(for: $0.name),
                 path: $0.canonicalPath)
            }
            let changed = entries.map { $0.path } != self.apps.map { $0.path }
            self.apps = entries
            if changed, self.isVisible { self.rebuildRows() }
        }
    }

    // MARK: - Layout

    private func buildLayout(in content: NSView) {
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 20, weight: .light)
        searchField.placeholderString = "输入名字打开 App、文件夹、文件或网址…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // Search affordance at the right edge of the input row: a soft rounded
        // badge, so the field reads as a launcher box rather than a stray label.
        searchBadge.translatesAutoresizingMaskIntoConstraints = false
        // Configuration first: it only applies to the symbol image set afterwards.
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        searchIcon.image = NSImage(systemSymbolName: "sparkle.magnifyingglass",
                                   accessibilityDescription: "搜索")
            ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索")
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchBadge.addSubview(searchIcon)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(labelWithString: "↑↓ 选择 · ⏎ 打开 · esc 关闭")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(searchField)
        content.addSubview(searchBadge)
        content.addSubview(separator)
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(footer)

        listHeightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: searchBadge.leadingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            searchBadge.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchBadge.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchBadge.widthAnchor.constraint(equalToConstant: 22),
            searchBadge.heightAnchor.constraint(equalToConstant: 22),
            searchIcon.centerXAnchor.constraint(equalTo: searchBadge.centerXAnchor),
            searchIcon.centerYAnchor.constraint(equalTo: searchBadge.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),
            searchIcon.heightAnchor.constraint(equalToConstant: 14),

            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            listHeightConstraint,

            emptyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            emptyLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    /// Coalesces the panel resize. Typing and deleting produce a burst of result
    /// counts; resizing (and re-blurring the HUD backdrop) for each of them is
    /// what made the launcher feel laggy. One resize after the burst instead.
    private func scheduleResize() {
        pendingResize?.cancel()
        resizeGeneration += 1
        let generation = resizeGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.resizeGeneration else { return }
            self.pendingResize = nil
            self.applyRowGeometry()
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDelay, execute: work)
    }

    private func cancelPendingResize() {
        pendingResize?.cancel()
        pendingResize = nil
        resizeGeneration += 1
    }

    /// Top edge stays put while the panel grows / shrinks with the result count.
    /// A same-height refresh (the common case while typing) skips the whole
    /// relayout/redraw, so keystrokes stay smooth.
    private func applyRowGeometry() {
        guard let window, let content = window.contentView else { return }
        let visibleRows = min(rows.count, Self.maxVisibleRows)
        let targetListHeight = rows.isEmpty ? 26 : CGFloat(visibleRows) * Self.rowHeight
        let heightChanged = abs(listHeightConstraint.constant - targetListHeight) > 0.5
        listHeightConstraint.constant = targetListHeight
        guard heightChanged else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(90, content.fittingSize.height)
        guard abs(window.frame.height - height) > 0.5 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size = NSSize(width: Self.width, height: height)
        frame.origin.y = top - height
        window.setFrame(frame, display: true)
    }

    /// Horizontally centred, a comfortable distance below the menu bar, on the
    /// screen the pointer is on (that is where the user is looking).
    private func positionWindow() {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var frame = window.frame
        frame.origin.x = min(max(visible.midX - frame.width / 2, visible.minX + 8),
                             visible.maxX - frame.width - 8)
        frame.origin.y = visible.maxY - frame.height - min(140, visible.height * 0.2)
        window.setFrame(frame, display: false)
    }

    // MARK: - Query / results

    /// Coalesces keystrokes: only the last one within `filterDelay` triggers a
    /// rebuild, so holding a key down no longer queues a dozen full rescans.
    private func scheduleRebuildRows() {
        pendingFilter?.cancel()
        filterGeneration += 1
        let generation = filterGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.filterGeneration else { return }
            self.pendingFilter = nil
            self.rebuildRows()
        }
        pendingFilter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.filterDelay, execute: work)
    }

    private func cancelPendingFilter() {
        pendingFilter?.cancel()
        pendingFilter = nil
        filterGeneration += 1
    }

    /// ⏎ / ↑↓ arrive inside the debounce window: apply the pending query first so
    /// the opened row is the one that matches what is actually in the field.
    private func flushPendingFilterIfNeeded() {
        guard pendingFilter != nil else { return }
        cancelPendingFilter()
        rebuildRows()
    }

    private func rebuildRows(immediateResize: Bool = false) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            // Configured items only: hundreds of installed apps on an empty query
            // is noise.
            rows = items.map { .item($0) }
        } else {
            let tokens = Self.tokens(for: query)
            var scored: [(row: LauncherRow, score: Int)] = []
            for item in items {
                let extra = "\(item.kind.displayName) \(item.target)".lowercased()
                if let score = Self.score(tokens: tokens, nameKey: item.name.lowercased(),
                                          initials: Self.initials(for: item.name), extra: extra) {
                    // Configured items win ties: the user chose them on purpose.
                    scored.append((.item(item), score + 1))
                }
            }
            for command in SystemCommand.allCases {
                // System rows only ever exist for a typed query (empty query keeps
                // the list clean) and win ties like configured items do.
                if let score = Self.score(tokens: tokens, nameKey: command.title,
                                          initials: "", extra: command.keywords) {
                    scored.append((.system(command), score + 1))
                }
            }
            for entry in apps where !configuredPaths.contains(entry.path) {
                if let score = Self.score(tokens: tokens, nameKey: entry.key,
                                          initials: entry.initials, extra: "") {
                    scored.append((.app(entry.app), score))
                }
            }
            rows = Array(scored.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.row.title.localizedStandardCompare(rhs.row.title) == .orderedAscending
            }.prefix(Self.resultLimit).map(\.row))
            // Nothing matched → Alfred-style fallback: a typed path / URL opens
            // as-is, anything else becomes a Google search in the default browser.
            if rows.isEmpty {
                if let direct = Self.directCandidate(query) {
                    rows = [.direct(direct)]
                } else {
                    rows = [.webSearch(query)]
                }
            }
        }

        tableView.reloadData()
        selectedIndex = rows.isEmpty ? -1 : 0
        applySelection()
        updateEmptyLabel(query: query)
        if immediateResize {
            cancelPendingResize()
            applyRowGeometry()
        } else {
            scheduleResize()
        }
    }

    private static func tokens(for query: String) -> [String] {
        query.lowercased().split(separator: " ").map(String.init)
    }

    /// First letter of every word: "Google Chrome" → "gc", so initials work as a
    /// search term the way they do in Alfred.
    private static func initials(for name: String) -> String {
        name.split { !$0.isLetter && !$0.isNumber }
            .compactMap { $0.first }
            .map { String($0).lowercased() }
            .joined()
    }

    /// Every whitespace-separated token must appear somewhere; a name hit beats
    /// an initial hit, which beats an extra-field hit, so "sa" ranks Safari above
    /// an item whose path merely contains "sa". Inputs are already lower-cased.
    private static func score(tokens: [String], nameKey: String, initials: String,
                              extra: String) -> Int? {
        var score = 0
        for token in tokens {
            if nameKey.hasPrefix(token) {
                score += 3
            } else if nameKey.contains(token) {
                score += 2
            } else if initials.hasPrefix(token) {
                score += 2
            } else if extra.contains(token) {
                score += 1
            } else {
                return nil
            }
        }
        return score
    }

    /// Spaces mean prose, not a path: "hello world." must become a web search,
    /// not a failed attempt to open a file called `hello world.`. The same goes
    /// for version-ish input: "1.5" / "v1.2" is prose, only a domain-shaped
    /// string ("example.com", "192.168.1.1") or an explicit path / URL opens.
    private static func directCandidate(_ query: String) -> String? {
        guard !query.contains(" ") else { return nil }
        if query.hasPrefix("/") || query.hasPrefix("~") || query.contains("/") { return query }
        let labels = query.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, !last.isEmpty else { return nil }
        let looksLikeTLD = last.count >= 2 && last.allSatisfy { $0.isLetter }
        let looksLikeIPv4 = labels.count == 4 && last.allSatisfy { $0.isNumber }
        return looksLikeTLD || looksLikeIPv4 ? query : nil
    }

    private static func googleSearchURL(for term: String) -> String {
        let escaped = term.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? term
        return "https://www.google.com/search?q=\(escaped)"
    }

    /// Only touches the label when something actually changes: a `stringValue`
    /// write invalidates layout, which is exactly what we are trying to avoid.
    private func updateEmptyLabel(query: String) {
        let shouldHide = !rows.isEmpty
        if emptyLabel.isHidden != shouldHide { emptyLabel.isHidden = shouldHide }
        guard shouldHide else { return }
        let text = query.isEmpty
            ? "还没有快捷启动项 · 在「设置 → 快捷启动」里添加，或直接输入名字搜索已安装的 App"
            : "没有匹配「\(query)」的项目"
        if emptyLabel.stringValue != text { emptyLabel.stringValue = text }
    }

    private func applySelection() {
        guard selectedIndex >= 0, selectedIndex < rows.count else {
            tableView.deselectAll(nil)
            return
        }
        let indexes = IndexSet(integer: selectedIndex)
        if tableView.selectedRowIndexes != indexes {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        // Row 0/1 is already on screen; scrolling only matters further down.
        if selectedIndex > 1 { tableView.scrollRowToVisible(selectedIndex) }
    }

    private func moveSelection(by delta: Int) {
        flushPendingFilterIfNeeded()
        guard !rows.isEmpty else { return }
        selectedIndex = max(0, min(rows.count - 1, selectedIndex + delta))
        applySelection()
    }

    private func submit() {
        flushPendingFilterIfNeeded()
        guard selectedIndex >= 0, selectedIndex < rows.count else { return }
        let row = rows[selectedIndex]
        // Dismiss first: the opened app must not appear behind a floating panel.
        dismiss()
        switch row {
        case .item(let item):
            onOpenItem?(item)
        case .app(let app):
            onOpenApp?(app.url)
        case .system(let command):
            onOpenSystem?(command)
        case .direct(let raw):
            onOpenDirect?(raw)
        case .webSearch(let term):
            // The URL goes through NSWorkspace, i.e. the user's DEFAULT browser
            // (Chrome here) — the same reason Alfred's Google search opens there.
            onOpenDirect?(Self.googleSearchURL(for: term))
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        selectedIndex = row
        submit()
    }

    // MARK: - Outside click

    private func installOutsideMonitors() {
        guard outsideMonitors.isEmpty else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.handleOutsideClick() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handleOutsideClick() }
            return event
        }
        outsideMonitors = [global, local].compactMap { $0 }
    }

    private func removeOutsideMonitors() {
        outsideMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideMonitors = []
    }

    private func handleOutsideClick() {
        guard let window, window.isVisible else { return }
        if !window.frame.contains(NSEvent.mouseLocation) {
            dismiss()
        }
    }
}

// MARK: - Search field behaviour

extension LauncherWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleRebuildRows()
    }

    /// The field editor is the real first responder, so Return / arrows / esc are
    /// intercepted through the command selector — a keyDown override on the text
    /// field would never fire.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }
}

// MARK: - Table

extension LauncherWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        // Reused cells: rebuilding five view hierarchies + their constraints on
        // every keystroke was a visible hitch in the launcher.
        let cell = (tableView.makeView(withIdentifier: LauncherCell.reuseIdentifier, owner: self)
            as? LauncherCell) ?? LauncherCell(frame: .zero)
        switch rows[row] {
        case .item(let item):
            let detail = item.hotkey.map { "\(item.kind.displayName) · \($0.displayText)" }
                ?? item.kind.displayName
            cell.configure(title: item.name, detail: detail, icon: icon(for: item))
        case .app(let app):
            cell.configure(title: app.name, detail: "应用程序",
                           icon: fileIcon(atPath: app.url.path))
        case .system(let command):
            cell.configure(title: command.title, detail: command.detail,
                           icon: command.icon)
        case .direct(let raw):
            cell.configure(title: "打开「\(raw)」", detail: "按 ⏎ 用系统默认方式打开",
                           icon: Self.symbolIcon("arrow.up.forward.app"))
        case .webSearch(let term):
            cell.configure(title: "用 Google 搜索「\(term)」",
                           detail: "按 ⏎ 在默认浏览器中搜索",
                           icon: Self.symbolIcon("magnifyingglass"))
        }
        return cell
    }

    private static func symbolIcon(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Launch-item icons cost a bundle lookup (`resolvedURL` + NSWorkspace), so
    /// they are cached per item id for the lifetime of one panel session.
    private func icon(for item: LaunchItem) -> NSImage? {
        if let cached = itemIconCache[item.id] { return cached }
        let icon = item.icon ?? Self.symbolIcon("app")
        if let icon { itemIconCache[item.id] = icon }
        return icon
    }

    private func fileIcon(atPath path: String) -> NSImage? {
        if let cached = fileIconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        fileIconCache[path] = icon
        return icon
    }
}

/// One reusable result row: icon + title + detail, laid out exactly once.
private final class LauncherCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("launcherResultCell")

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, detail: String, icon: NSImage?) {
        iconView.image = icon
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
    }
}

/// Soft rounded backdrop behind the search glyph; `updateLayer` keeps the colour
/// correct when the system switches between light and dark appearance.
private final class LauncherSearchBadge: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    }
}

/// Borderless panels cannot become key by default, and without key status the
/// search field never receives keystrokes.
private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
