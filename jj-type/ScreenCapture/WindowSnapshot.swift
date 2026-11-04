//
//  WindowSnapshot.swift
//  jj-type
//
//  Snapshot of on-screen window geometry taken right before freezing the
//  displays; feeds the "hover a window to select it" affordance.
//

import AppKit
import CoreGraphics

nonisolated struct WindowSnapshot: Sendable {
    let windowID: CGWindowID
    /// AppKit global coordinates (bottom-left origin).
    let rect: CGRect
}

nonisolated enum WindowHitTester {
    /// `primaryMaxY` is NSScreen.screens.first.frame.maxY — it converts the
    /// CoreGraphics top-left global space into AppKit's bottom-left space.
    static func snapshot(primaryMaxY: CGFloat) -> [WindowSnapshot] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var snapshots: [WindowSnapshot] = []
        snapshots.reserveCapacity(raw.count)

        for info in raw {
            guard let layer = info[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0 else { continue }
            if let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
               pid.int32Value == ownPID { continue }
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0.01 { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  cgRect.width >= 40, cgRect.height >= 40 else { continue }
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }

            let rect = CGRect(x: cgRect.minX,
                              y: primaryMaxY - cgRect.maxY,
                              width: cgRect.width,
                              height: cgRect.height)
            snapshots.append(WindowSnapshot(windowID: number.uint32Value, rect: rect))
        }
        return snapshots
    }

    /// Front-to-back: the first window containing the point wins.
    static func window(at point: CGPoint, in snapshots: [WindowSnapshot]) -> WindowSnapshot? {
        snapshots.first { $0.rect.contains(point) }
    }
}
