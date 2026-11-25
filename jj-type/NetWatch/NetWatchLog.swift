//
//  NetWatchLog.swift
//  jj-type
//
//  Durable log for the network watchdog. A release build's NSLog does not
//  reach the unified log and its stderr is discarded, so every decision and
//  every command result is appended to a file the user can actually read.
//  Append + 256 KB rotation: the live file is moved to `netwatch.log.1`
//  (one generation kept) instead of being truncated in place.
//

import Foundation

nonisolated enum NetWatchLog {
    static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let directory = base.appendingPathComponent("Logs/JJType", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("netwatch.log")
    }()

    /// One rotated generation is kept next to the live file. Truncating in
    /// place erased the whole history at once — including the incident that
    /// caused the growth — so the previous generation is moved aside instead.
    /// Total footprint stays bounded at ~2 × maxBytes.
    static let backupURL = logURL.appendingPathExtension("1")

    private static let queue = DispatchQueue(label: "com.aigens.jj-type.netwatch.log")
    private static let maxBytes = 256 * 1024
    private static let formatter = ISO8601DateFormatter()

    static func note(_ message: String) {
        queue.async {
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let manager = FileManager.default
            let size = (try? manager.attributesOfItem(atPath: logURL.path))?[.size] as? Int ?? 0
            if size > maxBytes {
                rotate(manager)
                try? data.write(to: logURL)
            } else if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Moves the live file to `netwatch.log.1` (replacing the older backup)
    /// so the tail of the previous generation survives a rotation.
    private static func rotate(_ manager: FileManager) {
        try? manager.removeItem(at: backupURL)
        try? manager.moveItem(at: logURL, to: backupURL)
    }
}
