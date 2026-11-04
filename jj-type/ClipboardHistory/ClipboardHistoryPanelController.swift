//
//  ClipboardHistoryPanelController.swift
//  jj-type
//
//  Clipboard history panel on the launcher skeleton: one non-activating HUD,
//  type to filter, ⏎ pastes the selected entry back into the app that was
//  frontmost when the panel opened, ⌘⏎ copies only, esc / outside click
//  dismisses. The panel never activates the app, so the original target keeps
//  its focus ring and only the panel takes keystrokes.
//

import AppKit

final class ClipboardHistoryPanelController: NSWindowController {
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var listHeightConstraint: NSLayoutConstraint!
    private var outsideMonitors: [Any] = []
    /// ⌘⏎ interception: the field editor's doCommandBy callback cannot
    /// reliably read the ⌘ modifier (NSEvent.modifierFlags has already moved
    /// on), so the raw keyDown event is intercepted here instead.
    private var keyMonitor: Any?

    /// Snapshot of the app to paste into, taken when the panel opens.
    private var previousApp: NSRunningApplication?
    private var allEntries: [ClipboardEntry] = []
    private var filtered: [ClipboardEntry] = []
    private var selectedIndex = -1

    /// Same coalescing constants as the launcher: keystroke filtering at 60 ms,
    /// the (expensive, re-blurring) HUD resize at 250 ms.
    private var filterGeneration = 0
    private var pendingFilter: DispatchWorkItem?
    private static let filterDelay: TimeInterval = 0.06
    private var resizeGeneration = 0
    private var pendingResize: DispatchWorkItem?
    private static let resizeDelay: TimeInterval = 0.25

    private static let width: CGFloat = 600
    private static let rowHeight: CGFloat = 46
    private static let maxVisibleRows = 7

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    convenience init() {
        let panel = ClipboardHistoryPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
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

    /// Opens the panel with the current history. `entries` is newest first.
    func present(entries: [ClipboardEntry]) {
        // Paste target = whoever is focused BEFORE our panel shows up.
        previousApp = NSWorkspace.shared.frontmostApplication
        allEntries = entries
        cancelPendingFilter()
        searchField.stringValue = ""
        rebuildRows(immediateResize: true)
        positionWindow()
        guard let window else { return }
        // orderFrontRegardless, NOT makeKeyAndOrderFront: `orderFront` is a
        // no-op while the app is inactive (see LauncherWindowController).
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(searchField)
        installOutsideMonitors()
        installKeyMonitor()

        // Safety net (same as the launcher): if this Space refuses to give the
        // non-activating panel key status, activate so typing always works.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  window.isVisible, !window.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            window.makeFirstResponder(self.searchField)
        }
    }

    /// Single dismissal path (esc / outside click / after pasting).
    func dismiss() {
        cancelPendingFilter()
        cancelPendingResize()
        removeOutsideMonitors()
        removeKeyMonitor()
        window?.orderOut(nil)
    }

    // MARK: - Layout

    private func buildLayout(in content: NSView) {
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 20, weight: .light)
        searchField.placeholderString = "搜索剪贴板历史…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clipboard"))
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

        let footer = NSTextField(labelWithString: "↑↓ 选择 · ⏎ 粘贴到原应用 · ⌘⏎ 仅复制 · ⌥⌫ 删除 · esc 关闭")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(searchField)
        content.addSubview(separator)
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(footer)

        listHeightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.heightAnchor.constraint(equalToConstant: 26),

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

    /// Horizontally centred below the menu bar on the pointer's screen —
    /// identical placement policy to the launcher.
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

    // MARK: - Filter / resize coalescing (launcher patterns)

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

    private func flushPendingFilterIfNeeded() {
        guard pendingFilter != nil else { return }
        cancelPendingFilter()
        rebuildRows()
    }

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

    /// Top edge stays put; a same-height refresh skips the relayout entirely.
    private func applyRowGeometry() {
        guard let window, let content = window.contentView else { return }
        let visibleRows = min(filtered.count, Self.maxVisibleRows)
        let targetListHeight = filtered.isEmpty ? 26 : CGFloat(visibleRows) * Self.rowHeight
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

    // MARK: - Rows

    private func rebuildRows(immediateResize: Bool = false) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filtered = allEntries
        } else {
            // Text entries match their content; image entries only match the
            // obvious keywords ("图片" / "image" / "photo").
            filtered = allEntries.filter { entry in
                switch entry.kind {
                case .text(let text):
                    return text.localizedStandardContains(query)
                case .image:
                    // Image rows only match the obvious keywords.
                    return "图片 image photo".localizedStandardContains(query)
                }
            }
        }

        tableView.reloadData()
        selectedIndex = filtered.isEmpty ? -1 : 0
        applySelection()
        updateEmptyLabel(query: query)
        if immediateResize {
            cancelPendingResize()
            applyRowGeometry()
        } else {
            scheduleResize()
        }
    }

    /// Only touches the label when something actually changes.
    private func updateEmptyLabel(query: String) {
        let shouldHide = !filtered.isEmpty
        if emptyLabel.isHidden != shouldHide { emptyLabel.isHidden = shouldHide }
        guard shouldHide else { return }
        let text = allEntries.isEmpty
            ? "还没有剪贴板记录 · 复制点什么试试"
            : "没有匹配「\(query)」的记录"
        if emptyLabel.stringValue != text { emptyLabel.stringValue = text }
    }

    private func applySelection() {
        guard selectedIndex >= 0, selectedIndex < filtered.count else {
            tableView.deselectAll(nil)
            return
        }
        let indexes = IndexSet(integer: selectedIndex)
        if tableView.selectedRowIndexes != indexes {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        if selectedIndex > 1 { tableView.scrollRowToVisible(selectedIndex) }
    }

    private func moveSelection(by delta: Int) {
        flushPendingFilterIfNeeded()
        guard !filtered.isEmpty else { return }
        selectedIndex = max(0, min(filtered.count - 1, selectedIndex + delta))
        applySelection()
    }

    private func submit() {
        flushPendingFilterIfNeeded()
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return }
        let entry = filtered[selectedIndex]
        let previous = previousApp
        // Dismiss first so the synthetic ⌘V never lands on the outgoing HUD.
        dismiss()
        ClipboardHistoryService.shared.paste(entry: entry, previousApp: previous)
    }

    /// ⌘⏎ path (key monitor): copy without pasting, then close.
    private func submitCopyOnly() {
        flushPendingFilterIfNeeded()
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return }
        let entry = filtered[selectedIndex]
        dismiss()
        ClipboardHistoryService.shared.copyOnly(entry)
        CaptureToast.shared.show("已复制", symbol: "doc.on.doc")
    }

    /// ⌥⌫ path (key monitor, utils-8): delete the selected entry in place —
    /// the list rebuilds around the deleted index so the next entry slides
    /// into the selection instead of jumping back to the top.
    private func removeSelectedEntry() {
        flushPendingFilterIfNeeded()
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return }
        let entry = filtered[selectedIndex]
        ClipboardHistoryService.shared.remove(entry)
        if let index = allEntries.firstIndex(where: { $0.id == entry.id }) {
            allEntries.remove(at: index)
        }
        let keptIndex = selectedIndex
        rebuildRows(immediateResize: false)
        // Restore a sensible selection: the entry that took the deleted one's
        // place, clamped for a deleted tail row.
        if !filtered.isEmpty {
            selectedIndex = min(keptIndex, filtered.count - 1)
            applySelection()
        }
    }

    // MARK: - ⌘⏎ interception

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                // ⌘⏎ (keyCode 36) = copy only — swallow it so the field editor
                // never sees a plain insertNewline for this press.
                if event.keyCode == 36,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                    self.submitCopyOnly()
                    return nil
                }
                // ⌥⌫ (keyCode 51) = delete the selected entry (utils-8). The
                // raw-event interception is the ONLY reliable spot — the field
                // editor turns a bare Delete into plain character editing and
                // drops the ⌥ from doCommandBy's view of the world.
                if event.keyCode == 51,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option) {
                    self.removeSelectedEntry()
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < filtered.count else { return }
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

extension ClipboardHistoryPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleRebuildRows()
    }

    /// The field editor is the real first responder — Return / arrows / esc go
    /// through the command selector, exactly as in the launcher.
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

extension ClipboardHistoryPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let cell = (tableView.makeView(withIdentifier: ClipboardHistoryCell.reuseIdentifier,
                                       owner: self) as? ClipboardHistoryCell)
            ?? ClipboardHistoryCell(frame: .zero)
        cell.configure(entry: filtered[row],
                       thumbnailProvider: ClipboardHistoryService.shared.thumbnail(for:),
                       relativeFormatter: Self.relativeFormatter)
        return cell
    }
}

/// One reusable history row: thumbnail / symbol + preview + relative time,
/// laid out exactly once.
private final class ClipboardHistoryCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("clipboardHistoryCell")

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

    func configure(entry: ClipboardEntry,
                   thumbnailProvider: (ClipboardEntry) -> NSImage?,
                   relativeFormatter: RelativeDateTimeFormatter) {
        let relative = relativeFormatter.localizedString(for: entry.date, relativeTo: Date())
        switch entry.kind {
        case .text(let text):
            iconView.image = NSImage(systemSymbolName: "doc.on.doc",
                                     accessibilityDescription: "文本")
            titleLabel.stringValue = text.replacingOccurrences(of: "\n", with: " ")
            detailLabel.stringValue = "\(relative) · \(text.count) 字符"
        case .image(_, let width, let height):
            iconView.image = thumbnailProvider(entry)
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "图片")
            titleLabel.stringValue = "图片 · \(width)×\(height)"
            detailLabel.stringValue = relative
        }
    }
}

/// Borderless panels cannot become key by default — without key status the
/// search field never receives keystrokes.
private final class ClipboardHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
