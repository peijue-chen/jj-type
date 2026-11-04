//
//  SelectionHandle.swift
//  jj-type
//
//  The 8 resize handles of a captured selection plus the geometry helpers
//  (normalize / resize / clamp) used while dragging. All coordinates are in
//  AppKit global space (bottom-left origin) unless stated otherwise.
//

import CoreGraphics

nonisolated enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        case .top, .left, .right, .bottom: return false
        }
    }

    func center(in selection: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: selection.minX, y: selection.maxY)
        case .top: return CGPoint(x: selection.midX, y: selection.maxY)
        case .topRight: return CGPoint(x: selection.maxX, y: selection.maxY)
        case .left: return CGPoint(x: selection.minX, y: selection.midY)
        case .right: return CGPoint(x: selection.maxX, y: selection.midY)
        case .bottomLeft: return CGPoint(x: selection.minX, y: selection.minY)
        case .bottom: return CGPoint(x: selection.midX, y: selection.minY)
        case .bottomRight: return CGPoint(x: selection.maxX, y: selection.minY)
        }
    }

    func rect(in selection: CGRect, size: CGFloat) -> CGRect {
        let point = center(in: selection)
        return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    /// Handles are small, so the hit area is grown by `tolerance` on every side.
    static func hitTest(_ point: CGPoint,
                        in selection: CGRect,
                        size: CGFloat = 7,
                        tolerance: CGFloat = 4) -> SelectionHandle? {
        for handle in allCases {
            let hitRect = handle.rect(in: selection, size: size)
                .insetBy(dx: -tolerance, dy: -tolerance)
            if hitRect.contains(point) { return handle }
        }
        return nil
    }
}

nonisolated enum SelectionGeometry {
    /// Two arbitrary drag corners → a positive rectangle.
    static func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(a.x - b.x),
               height: abs(a.y - b.y))
    }

    /// Moves the dragged edges only; never flips and never shrinks below 1pt.
    static func resized(_ selection: CGRect, handle: SelectionHandle, to point: CGPoint) -> CGRect {
        var minX = selection.minX
        var maxX = selection.maxX
        var minY = selection.minY
        var maxY = selection.maxY

        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .left: minX = point.x
        case .right: maxX = point.x
        case .bottomLeft: minX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomRight: maxX = point.x; minY = point.y
        }

        if maxX - minX < 1 {
            switch handle {
            case .left, .topLeft, .bottomLeft: minX = maxX - 1
            default: maxX = minX + 1
            }
        }
        if maxY - minY < 1 {
            switch handle {
            case .bottom, .bottomLeft, .bottomRight: minY = maxY - 1
            default: maxY = minY + 1
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Keeps the rectangle inside the desktop without changing its size
    /// (unless it is larger than the desktop itself).
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return rect }
        let width = Swift.min(rect.width, bounds.width)
        let height = Swift.min(rect.height, bounds.height)
        let x = Swift.min(Swift.max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = Swift.min(Swift.max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
