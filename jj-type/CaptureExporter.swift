//
//  CaptureExporter.swift
//  jj-type
//
//  Writes a captured image to disk (PNG / JPEG) and puts it on the pasteboard.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum CaptureFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    fileprivate var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }
}

nonisolated enum CaptureExportError: LocalizedError {
    case directoryUnwritable(URL)
    case encodeFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryUnwritable(let url):
            return "无法写入保存目录：\(url.path)"
        case .encodeFailed:
            return "图片编码失败"
        case .writeFailed(let message):
            return "写入文件失败：\(message)"
        }
    }
}

nonisolated enum CaptureExporter {
    /// Creates the directory when missing and writes `JJType-yyyyMMdd-HHmmss.<ext>`.
    @discardableResult
    static func save(_ image: CGImage, to directory: URL, format: CaptureFormat) throws -> URL {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw CaptureExportError.directoryUnwritable(directory)
            }
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw CaptureExportError.directoryUnwritable(directory)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        // One-second granularity: never overwrite a shot taken in the same second.
        var url = directory.appendingPathComponent("JJType-\(stamp).\(format.fileExtension)")
        var attempt = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("JJType-\(stamp)-\(attempt).\(format.fileExtension)")
            attempt += 1
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                               format.utType.identifier as CFString,
                                                               1, nil) else {
            throw CaptureExportError.encodeFailed
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureExportError.writeFailed(url.lastPathComponent)
        }
        return url
    }

    /// Copy-only path: the image reaches the pasteboard, nothing is written.
    /// `pointSize` keeps the pasted bitmap at the size the user saw on screen.
    @MainActor
    static func copyToPasteboard(_ image: CGImage, pointSize: CGSize) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let size = pointSize.width > 1 && pointSize.height > 1
            ? pointSize
            : CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        pasteboard.writeObjects([NSImage(cgImage: image, size: size)])
    }
}
