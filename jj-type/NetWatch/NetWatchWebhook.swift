//
//  NetWatchWebhook.swift
//  jj-type
//
//  Zoho Cliq-compatible webhook sender with an offline queue. When the network
//  is down the notification cannot be delivered — dropping it would lose the
//  very alert the user needs, so failed messages are persisted and retried on
//  the next successful probe.
//

import Foundation

/// One notification, rendered as a short log entry: what happened, when, why
/// and the outcome, separated from the next entry by a rule.
nonisolated struct NetWatchMessage {
    enum Kind: String {
        case recovered = "网络已恢复"
        case vpnRestored = "VPN 已重新连接"
        case vpnFailed = "VPN 连接失败"
        case switchFailed = "备用网络切换失败"
        case networkUnusable = "备用网络不可用"
        case heartbeat = "守护进程运行中"
        case test = "测试通知"
    }

    let kind: Kind
    /// Why this happened, e.g. "连续 10 分钟无法访问互联网".
    let reason: String
    /// What was done / what happened, e.g. "已切换到备用 Wi-Fi Aigens".
    let result: String
    /// Extra context (probe detail, interface, VPN state).
    let detail: String?
    let at: Date

    init(kind: Kind, reason: String, result: String, detail: String? = nil, at: Date = Date()) {
        self.kind = kind
        self.reason = reason
        self.result = result
        self.detail = detail
        self.at = at
    }

    /// Plain-text body, deliberately formatted as a log entry.
    var text: String {
        var lines: [String] = []
        lines.append("[JJType 网络守护] \(kind.rawValue)")
        lines.append("时间：\(NetWatchMessage.timestamp.string(from: at))")
        lines.append("主机：\(NetWatchMessage.hostName)")
        lines.append("原因：\(reason)")
        lines.append("结果：\(result)")
        if let detail, !detail.isEmpty {
            lines.append("详情：\(detail)")
        }
        lines.append(NetWatchMessage.separator)
        return lines.joined(separator: "\n")
    }

    static let separator = "----------------------------------------"

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let hostName: String = {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }()
}

nonisolated enum NetWatchWebhook {
    private static let lock = NSLock()
    private static let maxQueued = 50

    private static var queueURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("JJType", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("netwatch-queue.json")
    }

    // MARK: - Send

    /// POSTs `{"text": "..."}`. Zoho Cliq answers 204 on success.
    static func send(urlString: String, text: String) async -> Bool {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            NetWatchLog.note("webhook failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Sends now, or queues for the next successful probe.
    static func deliver(urlString: String, message: NetWatchMessage) async {
        let text = message.text
        if await send(urlString: urlString, text: text) {
            NetWatchLog.note("webhook sent: \(message.kind.rawValue)")
            return
        }
        enqueue(text)
    }

    // MARK: - Queue

    static func enqueue(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        var items = loadQueue()
        items.append(text)
        if items.count > maxQueued { items = Array(items.suffix(maxQueued)) }
        saveQueue(items)
        NetWatchLog.note("webhook queued (\(items.count) pending)")
    }

    /// Retries queued messages in order. Stops at the first failure so the
    /// remaining messages keep their order.
    static func flush(urlString: String) async {
        let pending = drainQueue()
        guard !pending.isEmpty else { return }
        for (index, text) in pending.enumerated() {
            if await send(urlString: urlString, text: text) { continue }
            requeue(Array(pending[index...]))
            return
        }
        NetWatchLog.note("webhook queue flushed (\(pending.count) sent)")
    }

    static var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadQueue().count
    }

    // MARK: - Private

    private static func drainQueue() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let items = loadQueue()
        saveQueue([])
        return items
    }

    private static func requeue(_ items: [String]) {
        lock.lock()
        defer { lock.unlock() }
        var current = loadQueue()
        current.insert(contentsOf: items, at: 0)
        if current.count > maxQueued { current = Array(current.suffix(maxQueued)) }
        saveQueue(current)
    }

    private static func loadQueue() -> [String] {
        guard let data = try? Data(contentsOf: queueURL),
              let items = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return items
    }

    private static func saveQueue(_ items: [String]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }
}
