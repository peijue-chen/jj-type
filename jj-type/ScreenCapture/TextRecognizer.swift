//
//  TextRecognizer.swift
//  jj-type
//
//  On-device OCR for the toolbar's "识别文字" action. Vision is synchronous and
//  CPU heavy, so callers must run it from a detached task — never on the main
//  actor (a 5K selection takes hundreds of milliseconds).
//
//  Accuracy work, in order of importance:
//   1. upscale small crops before recognition (a 30pt-tall UI strip is the hard
//      case; Vision wants roughly 40+ pixels of glyph height);
//   2. ask for the newest recognition revision with every supported language
//      instead of the request defaults;
//   3. rebuild the reading order ourselves — Vision returns per-fragment boxes,
//      so lines have to be clustered by their vertical position and joined
//      left-to-right, with spacing that respects CJK (no spaces inside Chinese).
//
//  Deliberately no paragraph merging: joining two rows that merely sit close
//  together would corrupt form labels and table rows, and "same order as on
//  screen" matters more than reflowing wrapped text.
//

import CoreGraphics
import Foundation
import Vision

nonisolated enum TextRecognitionError: LocalizedError {
    case noText
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noText:
            return "未识别到文字"
        case .failed(let message):
            return "识别文字失败：\(message)"
        }
    }
}

nonisolated enum TextRecognizer {
    /// Recognised text plus the line count the caller puts in its toast.
    struct Result: Sendable {
        let text: String
        let lineCount: Int
    }

    /// Preferred order: Chinese first (it is the differentiator), English
    /// second — Vision requires Chinese to be paired with English.
    private static let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    /// Newest revision this macOS build actually supports. Asking for a revision
    /// the OS does not know raises an Objective-C exception — `try?` cannot catch
    /// that — so the capability is resolved once, up front.
    private static let revision: Int = {
        let supported = VNRecognizeTextRequest.supportedRevisions
        if supported.contains(VNRecognizeTextRequestRevision3) {
            return VNRecognizeTextRequestRevision3
        }
        return supported.max() ?? VNRecognizeTextRequestRevision2
    }()

    /// Recognises text and returns it in reading order (top → bottom, left →
    /// right), one line per visual row.
    static func recognize(_ image: CGImage) throws -> Result {
        let request = VNRecognizeTextRequest()
        // Newest revision understands small print and CJK punctuation better.
        request.revision = revision
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0
        if !cachedLanguages.isEmpty {
            request.recognitionLanguages = cachedLanguages
        }

        let handler = VNImageRequestHandler(cgImage: upscaled(image), orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw TextRecognitionError.failed(error.localizedDescription)
        }

        guard let observations = request.results, !observations.isEmpty else {
            throw TextRecognitionError.noText
        }

        var candidates: [Line] = []
        candidates.reserveCapacity(observations.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            candidates.append(Line(text: text,
                                   box: observation.boundingBox,
                                   confidence: candidate.confidence))
        }
        guard !candidates.isEmpty else { throw TextRecognitionError.noText }
        let lines = deduplicated(candidates)

        let rows = assemble(lines)
        let text = rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TextRecognitionError.noText }
        return Result(text: text, lineCount: rows.count)
    }

    // MARK: - Pre-processing

    /// Vision loses small glyphs, so tiny crops (a single label, a table cell)
    /// are scaled up 2–3x before recognition. Large shots are left alone: the
    /// pixels are already big enough and the extra bitmap would cost memory.
    private static func upscaled(_ image: CGImage) -> CGImage {
        let shortest = CGFloat(min(image.width, image.height))
        guard shortest > 8 else { return image }
        let factor = min(3, max(1, 640 / shortest))
        guard factor > 1.01 else { return image }

        let width = Int((CGFloat(image.width) * factor).rounded())
        let height = Int((CGFloat(image.height) * factor).rounded())
        guard width > 0, height > 0, width <= 12_000, height <= 12_000 else { return image }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: - Reading order

    /// One recognised fragment in Vision's normalised, bottom-left space.
    private struct Line {
        let text: String
        let box: CGRect
        let confidence: Float
    }

    /// Vision sometimes reports the same fragment twice with slightly shifted
    /// boxes; keep only the most confident copy so the output never repeats a
    /// line.
    private static func deduplicated(_ lines: [Line]) -> [Line] {
        var accepted: [Line] = []
        accepted.reserveCapacity(lines.count)
        for line in lines.sorted(by: { $0.confidence > $1.confidence }) {
            let area = line.box.width * line.box.height
            let repeated = accepted.contains { other in
                guard other.text == line.text, area > 0 else { return false }
                let overlap = other.box.intersection(line.box)
                guard !overlap.isNull else { return false }
                return overlap.width * overlap.height >= area * 0.7
            }
            if !repeated {
                accepted.append(line)
            }
        }
        return accepted
    }

    /// Clusters fragments into visual rows (top → bottom) and joins each row
    /// left → right.
    private static func assemble(_ lines: [Line]) -> [String] {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let reference = rows.last?.first,
               abs(reference.box.midY - line.box.midY)
                   <= max(reference.box.height, line.box.height) * 0.6 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows
            .map { $0.sorted { $0.box.minX < $1.box.minX } }
            .map(joinRow)
            .filter { !$0.isEmpty }
    }

    /// Fragments of one visual line, joined with spaces only where the gap and
    /// the scripts ask for one (Chinese fragments must not be space-separated).
    private static func joinRow(_ row: [Line]) -> String {
        guard var text = row.first?.text, var previous = row.first?.box else { return "" }
        for line in row.dropFirst() {
            let height = max(previous.height, line.box.height)
            let gap = line.box.minX - previous.maxX
            let boundaryIsCJK = isCJK(text.last) || isCJK(line.text.first)
            if !boundaryIsCJK, gap > max(height * 0.18, 0.002) {
                text += " "
            }
            text += line.text
            previous = line.box
        }
        return text
    }

    private static func isCJK(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,   // CJK punctuation
             0x3040...0x30FF,   // kana
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xAC00...0xD7AF,   // hangul
             0xF900...0xFAFF,   // compatibility ideographs
             0xFF00...0xFFEF:   // full-width forms
            return true
        default:
            return false
        }
    }

    // MARK: - Language cache

    /// The installed Vision revision decides which languages actually exist, so
    /// the preference list is filtered against the runtime capability list once.
    private static let cachedLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.revision = revision
        request.recognitionLevel = .accurate
        guard let supported = try? request.supportedRecognitionLanguages(), !supported.isEmpty else {
            return []
        }
        let picked = preferredLanguages.filter { supported.contains($0) }
        return picked.isEmpty ? supported : picked
    }()
}
