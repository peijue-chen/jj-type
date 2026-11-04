//
//  DevToolWindowController.swift
//  jj-type
//
//  Developer tool window (⌥J, utils-8): JSON format/minify, JSON↔string
//  (escape/unescape a JSON string literal), Base64 and URI
//  (encodeURIComponent semantics) encode/decode. JSON formatting renders an
//  expandable/collapsible NSOutlineView tree (nodes built LAZILY per branch —
//  a 10 MB JSON never materializes its wrapper nodes until unfolded), with a
//  tree/text segmented switch.
//
//  Memory policy (user requirement): closing the window drops EVERYTHING —
//  the AppDelegate owner nils the whole controller (`onClosed`), and the
//  controller clears its texts and tree root beforehand, so a huge JSON
//  never lingers in memory after the window is gone.
//

import AppKit

/// One lazily-populated outline node wrapping a parsed JSON value.
/// Wrappers are built branch-by-branch in `ensureChildren` (called by the
/// outline only when a branch is about to be shown/expanded), so unfolded
/// branches cost nothing.
private final class JSONNode {
    enum Kind {
        case string, number, bool, nullValue, array, dictionary
    }

    let key: String?
    let value: Any
    let kind: Kind

    private var cachedChildren: [JSONNode]?
    var children: [JSONNode] {
        if let cachedChildren { return cachedChildren }
        let built: [JSONNode]
        switch value {
        case let dictionary as [String: Any]:
            built = dictionary.map { JSONNode(key: $0.key, value: $0.value) }
                .sorted { $0.key ?? "" < $1.key ?? "" }
        case let array as [Any]:
            built = array.enumerated().map { JSONNode(key: "\($0.offset)", value: $0.element) }
        default:
            built = []
        }
        cachedChildren = built
        return built
    }

    var isExpandable: Bool {
        switch value {
        case is [String: Any], is [Any]: return true
        default: return false
        }
    }

    /// "12 项" / "3 个键" summary shown on collapsed container rows.
    var countText: String {
        switch value {
        case let array as [Any]:
            return "\(array.count) 项"
        case let dictionary as [String: Any]:
            return "\(dictionary.count) 个键"
        default:
            return ""
        }
    }

    init(key: String?, value: Any) {
        self.key = key
        self.value = value
        if let number = value as? NSNumber {
            // JSON true/false arrive as CFBoolean-typed NSNumbers; every other
            // number (int/float) is a plain .number.
            kind = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool : .number
        } else if value is String {
            kind = .string
        } else if value is NSNull {
            kind = .nullValue
        } else if value is [Any] {
            kind = .array
        } else if value is [String: Any] {
            kind = .dictionary
        } else {
            kind = .string
        }
    }
}

final class DevToolWindowController: NSWindowController {
    /// Explicit frame persistence (TranslationWindow/QRWindow pattern).
    private static let frameKey = "jjtype.devToolWindowFrame"

    /// Fired when the window is closed: the AppDelegate owner nils its
    /// reference so the window, the texts and the JSON tree all deallocate
    /// (memory requirement — a big JSON never survives a closed window).
    var onClosed: (() -> Void)?

    private let inputTextView = NSTextView()
    private let resultTextView = NSTextView()

    // JSON tree result.
    private let outlineView = NSOutlineView()
    private var treeRoot: JSONNode?
    /// Pretty text backing the tree (复制结果 in tree mode copies THIS).
    private var prettyText: String = ""

    private let jsonPrettyButton = Theme.button("格式化", symbol: "increase.indent")
    private let jsonMinifyButton = Theme.button("压缩", symbol: "decrease.indent")
    private let jsonToStringButton = Theme.button("转字符串", symbol: "text.quote")
    private let stringToJsonButton = Theme.button("转JSON", symbol: "curlybraces")
    private let base64EncodeButton = Theme.button("编码", symbol: "arrow.up.forward")
    private let base64DecodeButton = Theme.button("解码", symbol: "arrow.down.backward")
    private let uriEncodeButton = Theme.button("编码", symbol: "link")
    private let uriDecodeButton = Theme.button("解码", symbol: "link.badge.plus")

    private let viewModeControl = NSSegmentedControl(
        labels: ["树形", "文本"], trackingMode: .selectOne, target: nil, action: nil)
    private let expandAllButton = Theme.button("全部展开", symbol: "chevron.down.square")
    private let collapseAllButton = Theme.button("全部折叠", symbol: "chevron.up.square")
    private let copyResultButton = Theme.primaryButton("复制结果", symbol: "doc.on.doc")
    private let swapButton = Theme.button("结果 → 输入", symbol: "arrow.uturn.down")
    private let statusLabel = NSTextField(labelWithString: "")

    private enum Transform: CaseIterable {
        case jsonPretty, jsonMinify, jsonToString, stringToJson,
             base64Encode, base64Decode, uriEncode, uriDecode

        var displayName: String {
            switch self {
            case .jsonPretty: return "JSON 格式化"
            case .jsonMinify: return "JSON 压缩"
            case .jsonToString: return "JSON 转字符串"
            case .stringToJson: return "字符串转 JSON"
            case .base64Encode: return "Base64 编码"
            case .base64Decode: return "Base64 解码"
            case .uriEncode: return "URI 编码"
            case .uriDecode: return "URI 解码"
            }
        }
    }

    convenience init() {
        let content = DevToolContentView(frame: NSRect(x: 0, y: 0, width: 560, height: 540))
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "JJType 开发工具"
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // ⌥J must SURFACE the tool: float above normal windows and follow the
        // active space — otherwise it hides behind other apps' windows.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 520, height: 440)
        self.init(window: window)
        window.contentViewController = NSViewController()
        window.contentViewController?.view = content
        content.controller = self
        buildLayout(in: content)

        let savedRect = UserDefaults.standard.string(forKey: Self.frameKey)
            .map(NSRectFromString) ?? .zero
        if savedRect.width > 50, savedRect.height > 50 {
            window.setFrame(savedRect, display: false)
        } else {
            window.center()
        }
        window.setFrameAutosaveName("jjtype.devToolWindow")
        Self.clampFrameToVisibleScreen(window)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveFrame() }
        }
    }

    // MARK: - Public API

    func present() {
        showWindow(nil)
        // Activate FIRST so the key-window promotion sticks over other apps.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(inputTextView)
    }

    /// Single close path (Esc/⌘W/toggle): clears every heavy variable FIRST
    /// (texts + tree), then hides and tells the owner to drop the controller.
    func closeAndRelease() {
        releaseHeavyState()
        window?.orderOut(nil)
        onClosed?()
    }

    /// Red close-button path: NSWindowController is the window's default
    /// delegate, so performClose lands here. The SAME memory rule applies —
    /// the texts and the JSON tree die with the window. The ownership drop
    /// is deferred off the close call stack (deallocating the window inside
    /// windowWillClose would recurse into the close machinery).
    func windowWillClose(_ notification: Notification) {
        releaseHeavyState()
        DispatchQueue.main.async { [weak self] in self?.onClosed?() }
    }

    private func releaseHeavyState() {
        inputTextView.string = ""
        resultTextView.string = ""
        treeRoot = nil
        prettyText = ""
        outlineView.reloadData()
    }

    // MARK: - Layout

    private func buildLayout(in view: NSView) {
        inputTextView.font = Theme.mono()
        inputTextView.isRichText = false
        inputTextView.allowsUndo = true
        inputTextView.backgroundColor = .textBackgroundColor
        let inputScroll = makeRoundedScroll(for: inputTextView)

        resultTextView.font = Theme.mono()
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.isRichText = false
        resultTextView.backgroundColor = .textBackgroundColor
        let resultScroll = makeRoundedScroll(for: resultTextView)

        // JSON tree: plain style, reused row views, lazy branch building.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("json"))
        outlineView.addTableColumn(column)
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 24
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.selectionHighlightStyle = .regular
        outlineView.dataSource = self
        outlineView.delegate = self
        installNodeContextMenu()
        let treeScroll = makeRoundedScroll(for: outlineView)

        // Transform rows: fixed-width right-aligned label + a LEADING-pinned
        // horizontal stack of buttons. Deliberately NOT NSGridView — its
        // column stretching pushed the last JSON-row button to the far right.
        let bindings: [(label: String, buttons: [(NSButton, Transform)])] = [
            ("JSON", [(jsonPrettyButton, .jsonPretty), (jsonMinifyButton, .jsonMinify),
                      (jsonToStringButton, .jsonToString), (stringToJsonButton, .stringToJson)]),
            ("Base64", [(base64EncodeButton, .base64Encode), (base64DecodeButton, .base64Decode)]),
            ("URI", [(uriEncodeButton, .uriEncode), (uriDecodeButton, .uriDecode)]),
        ]
        var rows: [NSView] = []
        for (label, rowButtons) in bindings {
            let labelField = Theme.formLabel(label)
            labelField.alignment = .right
            labelField.translatesAutoresizingMaskIntoConstraints = false
            labelField.widthAnchor.constraint(equalToConstant: 44).isActive = true
            var views: [NSView] = [labelField]
            for (button, transform) in rowButtons {
                button.target = self
                button.action = #selector(transformClicked(_:))
                button.tag = Transform.allCases.firstIndex(of: transform) ?? 0
                // Small chips: four buttons + label must fit the minimum
                // window width without pushing the last one out of the card.
                button.controlSize = .small
                button.font = .systemFont(ofSize: 12)
                views.append(button)
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            rows.append(row)
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        viewModeControl.target = self
        viewModeControl.action = #selector(viewModeChanged(_:))
        viewModeControl.segmentStyle = .rounded
        viewModeControl.selectedSegment = 0

        expandAllButton.target = self
        expandAllButton.action = #selector(expandAllClicked)
        expandAllButton.controlSize = .small
        collapseAllButton.target = self
        collapseAllButton.action = #selector(collapseAllClicked)
        collapseAllButton.controlSize = .small

        statusLabel.font = Theme.caption()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        copyResultButton.target = self
        copyResultButton.action = #selector(copyResultClicked)
        copyResultButton.isEnabled = false
        swapButton.target = self
        swapButton.action = #selector(swapClicked)
        swapButton.isEnabled = false
        let actionRow = NSStackView(views: [viewModeControl, expandAllButton,
                                            collapseAllButton, copyResultButton, swapButton])
        actionRow.spacing = 10

        let inputCard = Theme.card()
        inputCard.content.addArrangedSubview(sectionLabel("输入"))
        inputCard.content.addArrangedSubview(inputScroll)
        inputCard.content.addArrangedSubview(grid)

        // Result area: the tree and text scrollers STACK INSIDE ONE container
        // (same frame, one visible) — the card's arranged rows never change
        // with the mode switch, so NSStackView's hidden-view quirks cannot
        // leave blank space.
        let resultContainer = NSView()
        resultContainer.translatesAutoresizingMaskIntoConstraints = false
        [treeScroll, resultScroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            resultContainer.addSubview($0)
        }
        NSLayoutConstraint.activate([
            treeScroll.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor),
            treeScroll.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor),
            treeScroll.topAnchor.constraint(equalTo: resultContainer.topAnchor),
            treeScroll.bottomAnchor.constraint(equalTo: resultContainer.bottomAnchor),
            resultScroll.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor),
            resultScroll.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor),
            resultScroll.topAnchor.constraint(equalTo: resultContainer.topAnchor),
            resultScroll.bottomAnchor.constraint(equalTo: resultContainer.bottomAnchor),
        ])

        let resultCard = Theme.card()
        resultCard.content.addArrangedSubview(sectionLabel("结果"))
        resultCard.content.addArrangedSubview(resultContainer)
        resultCard.content.addArrangedSubview(actionRow)
        resultCard.content.addArrangedSubview(statusLabel)

        // Manual vertical assembly (NOT a single NSStackView): the input card
        // hugs its content, the RESULT card stretches to the window bottom —
        // growing the window grows the JSON tree area, nothing else.
        view.addSubview(inputCard)
        view.addSubview(resultCard)
        NSLayoutConstraint.activate([
            inputCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            inputCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            inputCard.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),

            resultCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            resultCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            resultCard.topAnchor.constraint(equalTo: inputCard.bottomAnchor, constant: 14),
            resultCard.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),

            inputScroll.widthAnchor.constraint(
                equalTo: inputCard.widthAnchor, constant: -Theme.cardPadding * 2),
            inputScroll.heightAnchor.constraint(equalToConstant: 140),
            grid.widthAnchor.constraint(
                lessThanOrEqualTo: inputCard.widthAnchor, constant: -Theme.cardPadding * 2),

            resultContainer.widthAnchor.constraint(
                equalTo: resultCard.widthAnchor, constant: -Theme.cardPadding * 2),
            // Floor height; every extra pixel of window height lands here
            // (vertical hugging 1 → the stack gives the container all slack).
            resultContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            actionRow.leadingAnchor.constraint(
                equalTo: resultCard.leadingAnchor, constant: Theme.cardPadding),
            statusLabel.leadingAnchor.constraint(
                equalTo: resultCard.leadingAnchor, constant: Theme.cardPadding),
        ])
        resultContainer.setContentHuggingPriority(.init(1), for: .vertical)

        // Text view starts hidden; the tree view is the default for JSON.
        applyViewMode()
    }

    private func makeRoundedScroll(for document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        Theme.sectionHeader(text)
    }

    /// Tree view exists only for a JSON result; everything else is text-only.
    private var treeAvailable: Bool { treeRoot != nil }

    private func applyViewMode() {
        let tree = treeAvailable && viewModeControl.selectedSegment == 0
        // Both scrollers live in the same container (constant layout) —
        // only the visibility flips.
        outlineView.enclosingScrollView?.isHidden = !tree
        resultTextView.enclosingScrollView?.isHidden = tree
        // The segmented switch (and the fold toggles) need a tree.
        viewModeControl.isEnabled = treeAvailable
        expandAllButton.isEnabled = tree
        collapseAllButton.isEnabled = tree
        if !treeAvailable {
            viewModeControl.setSelected(false, forSegment: 0)
            viewModeControl.setSelected(true, forSegment: 1)
        }
    }

    /// Expands every branch recursively — materializes ALL lazy wrappers, so
    /// a multi-MB document can take a beat; that is the user's explicit ask.
    @objc private func expandAllClicked() {
        guard treeAvailable else { return }
        outlineView.expandItem(nil, expandChildren: true)
    }

    /// Folds everything back to just the root row.
    @objc private func collapseAllClicked() {
        guard treeAvailable else { return }
        outlineView.collapseItem(nil, collapseChildren: true)
    }

    /// Right-click on a tree row: copy the value (containers copy their whole
    /// subtree as pretty JSON; leaves copy the raw value) or the key.
    private func installNodeContextMenu() {
        let menu = NSMenu()
        let copyValue = NSMenuItem(title: "复制值", action: #selector(copyNodeValue(_:)),
                                   keyEquivalent: "")
        copyValue.target = self
        let copySubtree = NSMenuItem(title: "复制子树 JSON", action: #selector(copyNodeSubtree(_:)),
                                     keyEquivalent: "")
        copySubtree.target = self
        let copyKey = NSMenuItem(title: "复制键", action: #selector(copyNodeKey(_:)),
                                 keyEquivalent: "")
        copyKey.target = self
        menu.addItem(copyValue)
        menu.addItem(copySubtree)
        menu.addItem(copyKey)
        outlineView.menu = menu
    }

    private func nodeAtClickedRow() -> JSONNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? JSONNode
    }

    /// Raw value copy: strings WITHOUT quotes, numbers/bools as-is.
    @objc private func copyNodeValue(_ sender: Any?) {
        guard let node = nodeAtClickedRow() else { return }
        let text: String
        switch node.kind {
        case .string:
            text = (node.value as? String) ?? ""
        case .bool:
            text = "\((node.value as? NSNumber)?.boolValue ?? false)"
        case .number:
            text = "\(node.value)"
        case .nullValue:
            text = "null"
        case .dictionary, .array:
            text = "\(node.value)"
        }
        copyTextAndToast(text)
    }

    /// Pretty JSON of the clicked (container) subtree.
    @objc private func copyNodeSubtree(_ sender: Any?) {
        guard let node = nodeAtClickedRow(),
              let data = try? JSONSerialization.data(withJSONObject: node.value,
                                                      options: [.prettyPrinted, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return }
        copyTextAndToast(text)
    }

    @objc private func copyNodeKey(_ sender: Any?) {
        guard let node = nodeAtClickedRow(), let key = node.key else { return }
        copyTextAndToast(key)
    }

    private func copyTextAndToast(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        CaptureToast.shared.show("已复制", symbol: "doc.on.doc")
    }

    @objc private func viewModeChanged(_ sender: NSSegmentedControl) {
        applyViewMode()
    }

    // MARK: - Transforms

    @objc private func transformClicked(_ sender: NSButton) {
        let transform = Transform.allCases[sender.tag]
        let input = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            setStatus("请先输入内容", color: .systemRed)
            return
        }
        let result = Self.apply(transform, to: input)
        if let output = result.output {
            resultTextView.string = output
            copyResultButton.isEnabled = true
            swapButton.isEnabled = true

            if transform == .jsonPretty, let object = result.object {
                // Tree mode: root node only — branches build lazily on expand.
                treeRoot = JSONNode(key: nil, value: object)
                prettyText = output
                outlineView.reloadData()
                outlineView.expandItem(nil)
                viewModeControl.setSelected(true, forSegment: 0)
                viewModeControl.setSelected(false, forSegment: 1)
                applyViewMode()
                setStatus("JSON 格式化完成 · \(output.count) 字符（树形可折叠）",
                          color: .secondaryLabelColor)
            } else {
                treeRoot = nil
                prettyText = output
                outlineView.reloadData()
                viewModeControl.setSelected(false, forSegment: 0)
                viewModeControl.setSelected(true, forSegment: 1)
                applyViewMode()
                setStatus("\(transform.displayName)完成 · \(output.count) 字符",
                          color: .secondaryLabelColor)
            }
        } else {
            setStatus("\(transform.displayName)失败：\(result.error ?? "未知错误")",
                      color: .systemRed)
        }
    }

    /// Pure string transforms — no state, safe to call from anywhere.
    /// Returns (output, error, object); object is the parsed JSON tree when
    /// the transform was jsonPretty (nil otherwise).
    private static func apply(_ transform: Transform,
                              to input: String) -> (output: String?, error: String?,
                                                    object: Any?) {
        switch transform {
        case .jsonPretty, .jsonMinify:
            guard let data = input.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data,
                                                                  options: [.fragmentsAllowed]) else {
                return (nil, "不是有效的 JSON", nil)
            }
            let options: JSONSerialization.WritingOptions =
                transform == .jsonPretty ? [.prettyPrinted, .fragmentsAllowed]
                                         : [.fragmentsAllowed]
            guard let output = try? JSONSerialization.data(withJSONObject: object,
                                                           options: options),
                  let text = String(data: output, encoding: .utf8) else {
                return (nil, "序列化失败", nil)
            }
            return (text, nil, transform == .jsonPretty ? object : nil)
        case .jsonToString:
            // Minified JSON escaped into ONE JSON string literal (with the
            // surrounding quotes) — ready to paste into a code constant.
            guard let data = input.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data,
                                                                  options: [.fragmentsAllowed]) else {
                return (nil, "不是有效的 JSON", nil)
            }
            guard let compact = try? JSONSerialization.data(withJSONObject: object,
                                                             options: [.fragmentsAllowed]),
                  let compactText = String(data: compact, encoding: .utf8),
                  let literal = try? JSONSerialization.data(withJSONObject: compactText,
                                                             options: [.fragmentsAllowed]),
                  let text = String(data: literal, encoding: .utf8) else {
                return (nil, "转义失败", nil)
            }
            return (text, nil, nil)
        case .stringToJson:
            // Accepts a full JSON string literal ("{\"a\":1}") or the escaped
            // body without the surrounding quotes; both unescape to the raw
            // JSON text. Backslashes/quotes are NOT re-escaped (that would
            // keep the escapes and no-op the conversion) — only raw line
            // breaks / tabs, which are illegal inside a JSON string, are
            // normalized so text copied straight out of a code editor parses.
            let body = input.count >= 2 && input.hasPrefix("\"") && input.hasSuffix("\"")
                ? String(input.dropFirst().dropLast())
                : input
            let normalized = body
                .replacingOccurrences(of: "\r\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            guard let data = ("\"\(normalized)\"").data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data,
                                                                  options: [.fragmentsAllowed]),
                  let text = object as? String else {
                return (nil, "不是有效的 JSON 字符串文本", nil)
            }
            return (text, nil, nil)
        case .base64Encode:
            guard let data = input.data(using: .utf8) else { return (nil, "编码失败", nil) }
            return (data.base64EncodedString(), nil, nil)
        case .base64Decode:
            guard let data = Data(base64Encoded: input),
                  let text = String(data: data, encoding: .utf8) else {
                return (nil, "不是有效的 Base64 文本", nil)
            }
            return (text, nil, nil)
        case .uriEncode:
            // JS encodeURIComponent semantics: everything except unreserved
            // marks A-Za-z0-9 - _ . ! ~ * ' ( ) is percent-encoded.
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
            guard let encoded = input.addingPercentEncoding(withAllowedCharacters: allowed) else {
                return (nil, "编码失败", nil)
            }
            return (encoded, nil, nil)
        case .uriDecode:
            guard let decoded = input.removingPercentEncoding else {
                return (nil, "不是有效的百分号编码文本", nil)
            }
            return (decoded, nil, nil)
        }
    }

    // MARK: - Result actions

    @objc private func copyResultClicked() {
        // Tree mode copies the pretty text (identical to the text view).
        let text = treeAvailable && viewModeControl.selectedSegment == 0
            ? prettyText
            : resultTextView.string
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        CaptureToast.shared.show("已复制结果", symbol: "doc.on.doc")
    }

    /// Puts the result back into the input box for chained conversions.
    @objc private func swapClicked() {
        let text = treeAvailable && viewModeControl.selectedSegment == 0
            ? prettyText
            : resultTextView.string
        guard !text.isEmpty else { return }
        inputTextView.string = text
        window?.makeFirstResponder(inputTextView)
        setStatus("结果已放回输入区", color: .secondaryLabelColor)
    }

    // MARK: - Private

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.textColor = color
        statusLabel.stringValue = text
    }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
        UserDefaults.standard.synchronize()
    }

    private static func clampFrameToVisibleScreen(_ window: NSWindow) {
        let frame = window.frame
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return }
        if !screens.contains(where: { $0.intersects(frame) }) {
            window.center()
            return
        }
        let best = screens.max {
            ($0.intersection(frame).width * $0.intersection(frame).height)
                < ($1.intersection(frame).width * $1.intersection(frame).height)
        }
        guard let visible = best, visible != frame else { return }
        var clamped = frame
        clamped.origin.x = min(max(clamped.origin.x, visible.minX), visible.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.origin.y, visible.minY), visible.maxY - clamped.height)
        window.setFrame(clamped, display: false)
    }
}

// MARK: - JSON outline (lazy branch building)

extension DevToolWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, child index: Int,
                     ofItem item: Any?) -> Any {
        let parent = (item as? JSONNode) ?? treeRoot
        return parent?.children[index] ?? NSObject()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? JSONNode) ?? treeRoot
        guard let node, node.isExpandable else { return 0 }
        // `children` builds THIS branch's wrappers on first touch — that is
        // the whole lazy guarantee: folded branches never allocate.
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? JSONNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? JSONNode else { return nil }
        let cell = (outlineView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("jsonRow"), owner: self)
            as? JSONRowView) ?? JSONRowView(frame: .zero)
        cell.configure(node: node)
        return cell
    }
}

/// One reused outline row: key label + value / summary, type-tinted.
private final class JSONRowView: NSTableCellView {
    private let keyLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("jsonRow")

        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        keyLabel.lineBreakMode = .byTruncatingMiddle

        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1

        let row = NSStackView(views: [keyLabel, valueLabel])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(node: JSONNode) {
        keyLabel.stringValue = node.key.map { "\"\($0)\":" } ?? ""
        switch node.kind {
        case .dictionary, .array:
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.stringValue = node.isExpandable
                ? "\(node.kind == .dictionary ? "{…}" : "[…]") \(node.countText)"
                : ""
        case .string:
            valueLabel.textColor = .systemGreen
            if let string = node.value as? String {
                valueLabel.stringValue = "\"\(string)\""
            }
        case .number:
            valueLabel.textColor = .systemBlue
            valueLabel.stringValue = "\(node.value)"
        case .bool:
            valueLabel.textColor = .systemPurple
            valueLabel.stringValue = "\(node.value)"
        case .nullValue:
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.stringValue = "null"
        }
    }
}

/// Esc / ⌘W / ⌘Q close the window AND release its memory.
private final class DevToolContentView: NSView {
    fileprivate weak var controller: DevToolWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            controller?.closeAndRelease()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           event.keyCode == 13 || event.keyCode == 12 { // W or Q
            controller?.closeAndRelease()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
