//
//  QRService.swift
//  jj-type
//
//  QR generation (CoreImage) and detection (Vision). Generation renders at
//  10 px per module so a pinned code stays crisp; detection runs on the
//  caller's background task, same pattern as TextRecognizer.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

enum QRError: LocalizedError {
    case noQRCode
    case generationFailed

    var errorDescription: String? {
        switch self {
        case .noQRCode:
            return "未检测到二维码"
        case .generationFailed:
            return "二维码生成失败"
        }
    }
}

enum QRService {
    /// Generates a QR code for `text`. `modulePixels` controls crispness —
    /// 10 px per module keeps a pinned 25-module code sharp at 250 pt.
    static func generateQR(for text: String, modulePixels: Int = 10) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw QRError.generationFailed }
        let scale = CGAffineTransform(scaleX: CGFloat(modulePixels), y: CGFloat(modulePixels))
        let scaled = output.transformed(by: scale)
        let context = CIContext()
        guard let image = context.createCGImage(scaled, from: scaled.extent) else {
            throw QRError.generationFailed
        }
        return image
    }

    /// Detects QR payloads in an image. `nonisolated` so it can run inside a
    /// detached task (never on the main actor).
    nonisolated static func recognizeQR(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
