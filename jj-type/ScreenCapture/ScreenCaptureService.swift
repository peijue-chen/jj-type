//
//  ScreenCaptureService.swift
//  jj-type
//
//  Freezes every display through ScreenCaptureKit and crops the final selection
//  out of the frozen frames. Everything here is nonisolated: capturing and
//  compositing 5K bitmaps must never run on the main actor.
//

import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Display geometry resolved on the main actor (NSScreen is main-thread affine)
/// and handed to the nonisolated capture service.
nonisolated struct DisplayTarget: Sendable {
    let displayID: CGDirectDisplayID
    /// AppKit global coordinates (bottom-left origin).
    let frame: CGRect
    let scale: CGFloat
}

/// A frozen, full-resolution snapshot of one display.
nonisolated struct CapturedDisplay: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    /// AppKit global coordinates (bottom-left origin).
    let screenFrame: CGRect
    let scale: CGFloat
    /// Full pixel-resolution frame (no cursor, no overlay).
    let image: CGImage

    var pixelSize: CGSize {
        CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
    }

    /// Actual pixels-per-point ratio of the frozen frame. Derived from the image
    /// itself (not just backingScaleFactor) so scaled display modes stay aligned
    /// with what the overlay draws.
    var pixelScaleX: CGFloat {
        screenFrame.width > 0 ? CGFloat(image.width) / screenFrame.width : scale
    }

    var pixelScaleY: CGFloat {
        screenFrame.height > 0 ? CGFloat(image.height) / screenFrame.height : scale
    }
}

nonisolated enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case displayMismatch(CGDirectDisplayID)
    case captureFailed(String)
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "未获得「屏幕录制」权限，请在系统设置中授权后重启 JJType"
        case .noDisplays:
            return "未检测到可截图的显示器"
        case .displayMismatch(let id):
            return "找不到显示器 \(id)，请重试"
        case .captureFailed(let message):
            return "截图失败：\(message)"
        case .cropFailed:
            return "裁剪截图失败，请重试"
        }
    }
}

nonisolated enum ScreenCaptureService {
    /// Keeps the non-Sendable shareable content usable inside the task group.
    private final class ContentBox: @unchecked Sendable {
        let content: SCShareableContent

        init(_ content: SCShareableContent) {
            self.content = content
        }
    }

    /// Captures all requested displays concurrently, preserving the input order.
    ///
    /// - Parameter includingOwnWindowIDs: windows of our own app that must still
    ///   be photographed — the pinned screenshots, which float above the capture
    ///   overlay. Everything else of ours (status menu, panels) stays excluded.
    static func captureAllDisplays(_ targets: [DisplayTarget],
                                   includingOwnWindowIDs: Set<CGWindowID> = []) async throws -> [CapturedDisplay] {
        guard !targets.isEmpty else { throw ScreenCaptureError.noDisplays }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        } catch {
            // SCStreamError.userDeclined and friends all mean "no permission".
            throw ScreenCaptureError.permissionDenied
        }

        let box = ContentBox(content)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pinnedWindowIDs = includingOwnWindowIDs

        let captured = try await withThrowingTaskGroup(of: CapturedDisplay.self) { group in
            for target in targets {
                group.addTask {
                    guard let display = box.content.displays.first(where: { $0.displayID == target.displayID }) else {
                        throw ScreenCaptureError.displayMismatch(target.displayID)
                    }
                    // Never photograph ourselves (status menu, result panel),
                    // except the pins the user explicitly keeps on screen.
                    let ownApps = box.content.applications.filter { $0.processID == ownPID }
                    let pinned = pinnedWindowIDs.isEmpty
                        ? []
                        : box.content.windows.filter { pinnedWindowIDs.contains($0.windowID) }
                    let filter = SCContentFilter(display: display,
                                                 excludingApplications: ownApps,
                                                 exceptingWindows: pinned)
                    let configuration = SCStreamConfiguration()
                    let pixelScale = CGFloat(filter.pointPixelScale)
                    let contentRect = filter.contentRect
                    configuration.width = max(1, Int((contentRect.width * pixelScale).rounded()))
                    configuration.height = max(1, Int((contentRect.height * pixelScale).rounded()))
                    configuration.showsCursor = false
                    configuration.captureResolution = .best

                    let image: CGImage
                    do {
                        image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                           configuration: configuration)
                    } catch {
                        throw ScreenCaptureError.captureFailed(error.localizedDescription)
                    }
                    return CapturedDisplay(displayID: target.displayID,
                                           screenFrame: target.frame,
                                           scale: target.scale,
                                           image: image)
                }
            }

            var result: [CapturedDisplay] = []
            for try await display in group {
                result.append(display)
            }
            return result
        }

        // Task groups complete out of order — restore the NSScreen order.
        // uniquingKeysWith: mirrored displays can report the same displayID.
        var order: [CGDirectDisplayID: Int] = [:]
        for (index, target) in targets.enumerated() where order[target.displayID] == nil {
            order[target.displayID] = index
        }
        return captured.sorted { (order[$0.displayID] ?? 0) < (order[$1.displayID] ?? 0) }
    }

    /// Crops the global selection out of the frozen frames and composites the
    /// parts that come from different displays into one image.
    ///
    /// Both the destination bitmap context and the AppKit selection use a
    /// bottom-left origin, so only the source rect (image space, top-left
    /// origin) needs a vertical flip.
    static func crop(selection: CGRect, from displays: [CapturedDisplay]) throws -> CGImage {
        let sel = selection.standardized
        guard sel.width >= 1, sel.height >= 1, !sel.isNull else {
            throw ScreenCaptureError.cropFailed
        }

        let center = CGPoint(x: sel.midX, y: sel.midY)
        // Everything is resampled to the resolution of the screen holding the
        // selection centre, so mixed 1x/2x desktops produce one clean bitmap.
        let targetScale = displays.first { $0.screenFrame.contains(center) }?.pixelScaleX
            ?? displays.first?.pixelScaleX
            ?? 1

        let outWidth = max(1, Int((sel.width * targetScale).rounded()))
        let outHeight = max(1, Int((sel.height * targetScale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: outWidth,
                                      height: outHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ScreenCaptureError.cropFailed
        }
        context.interpolationQuality = .high

        var didDraw = false
        for display in displays {
            let intersection = display.screenFrame.intersection(sel)
            guard !intersection.isNull, intersection.width >= 0.5, intersection.height >= 0.5 else { continue }

            let scaleX = display.pixelScaleX
            let scaleY = display.pixelScaleY
            let sx = (intersection.minX - display.screenFrame.minX) * scaleX
            let sy = (display.screenFrame.maxY - intersection.maxY) * scaleY
            let sourceRect = CGRect(x: sx,
                                    y: sy,
                                    width: intersection.width * scaleX,
                                    height: intersection.height * scaleY).integral
            let imageBounds = CGRect(x: 0, y: 0,
                                     width: CGFloat(display.image.width),
                                     height: CGFloat(display.image.height))
            let clampedSource = sourceRect.intersection(imageBounds)
            guard !clampedSource.isNull, clampedSource.width >= 1, clampedSource.height >= 1 else { continue }
            guard let part = display.image.cropping(to: clampedSource) else { continue }

            let destination = CGRect(x: (intersection.minX - sel.minX) * targetScale,
                                     y: (intersection.minY - sel.minY) * targetScale,
                                     width: intersection.width * targetScale,
                                     height: intersection.height * targetScale)
            context.draw(part, in: destination)
            didDraw = true
        }

        guard didDraw, let image = context.makeImage() else {
            throw ScreenCaptureError.cropFailed
        }
        return image
    }
}
