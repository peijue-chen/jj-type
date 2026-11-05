//
//  DiagnosticLog.swift
//  jj-type
//
//  File-backed diagnostics for flows whose failure is otherwise invisible
//  (a release build's NSLog goes to a discarded stderr and does not reach
//  the unified log — verified on this macOS; the Xcode Debug build DOES
//  appear in `log show`, which is why issues only reproduce "in the wild").
//  Same convention as FinderTerminal.note(): append + 256 KB rotation.
//

import Foundation

enum DiagnosticLog {
    static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let directory = base.appendingPathComponent("Logs/JJType", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ai.log")
    }()

    private static let formatter = ISO8601DateFormatter()

    /// NSLog is kept for Xcode runs; the file line is the durable trace.
    static func note(_ message: String) {
        NSLog("[JJType][AI] %@", message)
        guard let data = (formatter.string(from: Date()) + " " + message + "\n").data(using: .utf8) else {
            return
        }
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: logURL.path))?[.size] as? Int ?? 0
        if size > 256 * 1024 {
            try? data.write(to: logURL)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
