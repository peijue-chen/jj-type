//
//  NetWatchLog.swift
//  jj-type
//
//  Durable log for the network watchdog. A release build's NSLog does not
//  reach the unified log and its stderr is discarded, so every decision and
//  every command result is appended to a file the user can actually read.
//  Same convention as DiagnosticLog: append + 256 KB rotation.
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
}
