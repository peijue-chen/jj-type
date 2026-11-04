//
//  AppIndex.swift
//  jj-type
//
//  Cached list of installed .app bundles, so the launcher can find any
//  application the user types — not only the ones they added by hand.
//

import AppKit

struct DiscoveredApp: Equatable, Sendable {
    let name: String
    let url: URL
    /// Symlink-resolved real path. De-duplication against configured launch
    /// items must compare REAL locations: `/Applications/Safari.app` is only a
    /// symlink into the system cryptex, so the visible path is not unique.
    let canonicalPath: String
}

/// `nonisolated` on the type (SE-0449) opts this helper out of the project-wide
/// MainActor default: the directory scan must run off the main thread.
nonisolated final class AppIndex: @unchecked Sendable {
    static let shared = AppIndex()

    /// The scan is a plain directory walk; the lock only protects the cache
    /// (`@unchecked Sendable` is justified by it).
    private let lock = NSLock()
    private var cached: [DiscoveredApp]?
    private var cachedAt: Date?
    /// An app installed while JJType is running must show up without a relaunch;
    /// one walk costs ~35 ms on a background queue, so a short TTL is cheap.
    private static let maxAge: TimeInterval = 300

    func apps() -> [DiscoveredApp] {
        lock.lock()
        defer { lock.unlock() }
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < Self.maxAge {
            return cached
        }
        let scanned = Self.scan()
        cached = scanned
        cachedAt = Date()
        return scanned
    }

    /// Standard install locations. `/System/Cryptexes/...` is where Safari and a
    /// few system apps actually live since Ventura — `/Applications/Safari.app`
    /// is only a symlink to it.
    private static let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Cryptexes/App/System/Applications",
        "/System/Cryptexes/App/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    private static func scan() -> [DiscoveredApp] {
        var seen = Set<String>()
        var result: [DiscoveredApp] = []
        for root in roots {
            for path in bundlePaths(in: root) {
                // Deduplicate by the REAL location: a symlinked bundle must not
                // appear twice, and the first (user-visible) path wins.
                let canonical = URL(fileURLWithPath: path)
                    .resolvingSymlinksInPath().standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                var name = FileManager.default.displayName(atPath: path)
                if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
                guard !name.isEmpty else { continue }
                result.append(DiscoveredApp(name: name,
                                            url: URL(fileURLWithPath: path),
                                            canonicalPath: canonical))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `.app` bundles directly inside `directory` plus ONE nesting level (vendors
    /// ship `/Applications/Foo/Foo.app`).
    ///
    /// Uses the path/string API on purpose: the URL-based
    /// `contentsOfDirectory(at:includingPropertiesForKeys:options:)` silently
    /// drops SYMLINK entries here, which made Safari undiscoverable.
    private static func bundlePaths(in directory: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory)
        else { return [] }
        var bundles: [String] = []
        var subdirectories: [String] = []
        for name in names where !name.hasPrefix(".") {
            let path = (directory as NSString).appendingPathComponent(name)
            if name.lowercased().hasSuffix(".app") {
                bundles.append(path)
            } else if name != "Contents" {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    subdirectories.append(path)
                }
            }
        }
        for subdirectory in subdirectories {
            guard let nested = try? FileManager.default.contentsOfDirectory(atPath: subdirectory)
            else { continue }
            for name in nested where name.lowercased().hasSuffix(".app") && !name.hasPrefix(".") {
                bundles.append((subdirectory as NSString).appendingPathComponent(name))
            }
        }
        return bundles
    }
}
