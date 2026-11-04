//
//  ClipboardHistoryService.swift
//  jj-type
//
//  Background clipboard recorder: polls NSPasteboard.changeCount on the main
//  run loop (O(1) check every 0.5 s) and persists text + image entries, newest
//  first, capped at 500 (FIFO). Concealed / transient payloads (password
//  managers) and file copies are skipped by design; our own write-backs are
//  suppressed by snapshotting the changeCount around them.
//
//  Storage: ~/Library/Application Support/JJType/ClipboardHistory/ with
//  index.json (the entry array) plus one <uuid>.png per image entry. Saves are
//  coalesced (0.3 s) onto a serial utility queue; image files orphaned by a
//  crash mid-trim are reconciled away at the next launch.
//

import AppKit
import CoreGraphics

/// One recorded clipboard payload. Text carries its string inline; images are
/// stored as PNG files referenced by name, with pixel size for the row label.
struct ClipboardEntry: Codable, Identifiable, Equatable {
    enum Kind: Codable, Equatable {
        case text(String)
        case image(file: String, width: Int, height: Int)
    }

    let id: UUID
    let date: Date
    let kind: Kind
}

final class ClipboardHistoryService {
    static let shared = ClipboardHistoryService()

    static let entryLimit = 500

    /// Newest first. Read directly by the panel when it opens.
    private(set) var entries: [ClipboardEntry] = []

    private var pollTimer: Timer?
    /// The changeCount as last seen by us — either via polling or via our own
    /// writes (`noteOwnWrite`), which must never be recorded.
    private var lastSeenCount: Int

    private let directory: URL
    private let indexURL: URL
    /// Serial queue for PNG writes + index persistence (keeps file order and
    /// keeps main-thread work to the cheap decode/encode).
    private let ioQueue = DispatchQueue(label: "com.aigens.jj-type.clipboard.io", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private static let saveDelay: TimeInterval = 0.3

    /// Row thumbnails, keyed by file URL (a full-size decode per keystroke
    /// would be absurd; the cache holds the last references alive).
    private let thumbnailCache = NSCache<NSURL, NSImage>()

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        directory = support.appendingPathComponent("JJType/ClipboardHistory", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        lastSeenCount = NSPasteboard.general.changeCount
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadIndex()
        reconcileOrphanImages()
    }

    /// Starts the poller. Called once from applicationDidFinishLaunching.
    func start() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in self?.poll()
        }
    }

    // MARK: - Recording

    @objc private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastSeenCount else { return }
        lastSeenCount = count
        record(pasteboard)
    }

    private func record(_ pasteboard: NSPasteboard) {
        let types = pasteboard.types ?? []

        // Password managers (and polite writers) mark sensitive / ephemeral
        // payloads — never record those.
        if types.contains(Self.concealedType) || types.contains(Self.transientType) { return }
        // File copies are out of scope (decision: text + images only).
        if types.contains(.fileURL) { return }

        if let text = pasteboard.string(forType: .string) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Re-copying the identical content is a no-op, not a duplicate row.
            if case .text(let existing)? = entries.first?.kind, existing == text { return }
            insert(ClipboardEntry(id: UUID(), date: Date(), kind: .text(text)))
            return
        }

        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let fileName = "\(UUID().uuidString).png"
            let fileURL = directory.appendingPathComponent(fileName)
            // Dimensions first (cheap metadata read on the main thread); the
            // PNG normalization + file write run on the IO queue — only the
            // Sendable `data` crosses the boundary. A write failure rolls the
            // entry back out on the main actor.
            guard let rep = NSBitmapImageRep(data: data),
                  rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return }
            let entry = ClipboardEntry(id: UUID(), date: Date(),
                                       kind: .image(file: fileName,
                                                    width: rep.pixelsWide,
                                                    height: rep.pixelsHigh))
            insert(entry)
            ioQueue.async { [weak self, data, fileURL, entryId = entry.id] in
                let payload = NSBitmapImageRep(data: data)?
                    .representation(using: .png, properties: [:]) ?? data
                do {
                    try payload.write(to: fileURL)
                } catch {
                    NSLog("[JJType] clipboard image write failed: %@",
                          error.localizedDescription)
                    DispatchQueue.main.async {
                        self?.entries.removeAll { $0.id == entryId }
                        self?.scheduleSave()
                    }
                }
            }
        }
    }

    private func insert(_ entry: ClipboardEntry) {
        entries.insert(entry, at: 0)
        trimToLimit()
        scheduleSave()
    }

    /// FIFO trim: drops the oldest entries past the limit and deletes their
    /// image files on the IO queue.
    private func trimToLimit() {
        guard entries.count > Self.entryLimit else { return }
        let removed = Array(entries[Self.entryLimit...])
        entries = Array(entries[..<Self.entryLimit])
        deleteImageFiles(of: removed)
    }

    // MARK: - Read helpers (panel rows)

    func text(for entry: ClipboardEntry) -> String? {
        guard case .text(let text) = entry.kind else { return nil }
        return text
    }

    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard case .image(let file, _, _) = entry.kind else { return nil }
        let url = directory.appendingPathComponent(file)
        if let cached = thumbnailCache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        thumbnailCache.setObject(image, forKey: url as NSURL)
        return image
    }

    // MARK: - Write back

    /// ⏎ in the panel: put the entry on the pasteboard, then synthesize ⌘V
    /// into the app that was frontmost when the panel opened. Without the
    /// Accessibility grant it degrades to copy-only with a toast.
    func paste(entry: ClipboardEntry, previousApp: NSRunningApplication?) {
        writeToPasteboard(entry)
        guard AccessibilityPermission.isGranted else {
            CaptureToast.shared.show("已复制（缺少辅助功能权限，无法自动粘贴）",
                                     symbol: "doc.on.doc")
            return
        }
        // One beat for the panel to finish closing before the synthetic ⌘V,
        // so the keystroke cannot land on the outgoing HUD.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            // Our panel never activates the app, so the original target usually
            // still has focus; the activation dance is only the safety net for
            // the (rare) case where the panel's fallback activation kicked in.
            if let previousApp,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                   != previousApp.bundleIdentifier {
                previousApp.activate()
                let deadline = Date().addingTimeInterval(0.4)
                while Date() < deadline,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                          != previousApp.bundleIdentifier {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            Self.postCommandV()
        }
    }

    /// ⌘⏎ in the panel: copy without pasting.
    func copyOnly(_ entry: ClipboardEntry) {
        writeToPasteboard(entry)
    }

    private func writeToPasteboard(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.kind {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .image(let file, _, _):
            let url = directory.appendingPathComponent(file)
            if let data = try? Data(contentsOf: url) {
                pasteboard.setData(data, forType: .png)
            }
        }
        // Polite marker: our own write-back is ephemeral and must not pollute
        // other clipboard managers' histories either.
        pasteboard.setData(Data(), forType: Self.transientType)
        noteOwnWrite()
    }

    /// Snapshots the changeCount after our own pasteboard writes so the poller
    /// never records them.
    private func noteOwnWrite() {
        lastSeenCount = NSPasteboard.general.changeCount
    }

    /// Synthesizes ⌘V to the session tap (Accessibility only) — same pattern
    /// as TextCaptureService's ⌘C.
    private static func postCommandV() {
        let keyCodeV: CGKeyCode = 9 // kVK_ANSI_V
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        keyDown?.flags = CGEventFlags.maskCommand
        keyUp?.flags = CGEventFlags.maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    // MARK: - Management

    /// ⌥⌫ in the panel (utils-8): removes one entry, persists, and deletes
    /// its image file (if any) off the main thread.
    func remove(_ entry: ClipboardEntry) {
        let before = entries.count
        entries.removeAll { $0.id == entry.id }
        guard entries.count != before else { return }
        if case .image(let file, _, _) = entry.kind {
            thumbnailCache.removeObject(forKey: directory.appendingPathComponent(file) as NSURL)
        }
        scheduleSave()
        deleteImageFiles(of: [entry])
    }

    /// Settings → 工具 → 清空. Removes every entry and every stored image.
    func clearAll() {
        entries.removeAll()
        thumbnailCache.removeAllObjects()
        scheduleSave(immediate: true)
        ioQueue.async { [directory] in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension.lowercased() == "png" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Persistence

    private func scheduleSave(immediate: Bool = false) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performSave() }
        pendingSave = work
        if immediate {
            performSaveNowVia(work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
        }
    }

    /// immediate path still goes through the work item so a pending coalesced
    /// save is cancelled by the same mechanism.
    private func performSaveNowVia(_ work: DispatchWorkItem) {
        work.perform()
    }

    private func performSave() {
        pendingSave = nil
        let snapshot = entries
        let url = indexURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else {
            return
        }
        // Drop entries whose image file vanished (manual cleanup, disk issue).
        entries = decoded.filter { entry in
            guard case .image(let file, _, _) = entry.kind else { return true }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path)
        }
    }

    /// Deletes image files no longer referenced by the index (crash mid-trim,
    /// failed writes) and entries' files removed by trimming.
    private func deleteImageFiles(of removed: [ClipboardEntry]) {
        guard !removed.isEmpty else { return }
        ioQueue.async { [directory] in
            for entry in removed {
                guard case .image(let file, _, _) = entry.kind else { continue }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }

    private func reconcileOrphanImages() {
        let referenced = Set(entries.compactMap { entry -> String? in
            guard case .image(let file, _, _) = entry.kind else { return nil }
            return file
        })
        let dir = directory
        ioQueue.async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files
            where url.pathExtension.lowercased() == "png" && !referenced.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
