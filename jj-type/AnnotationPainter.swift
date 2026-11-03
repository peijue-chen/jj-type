//
//  AnnotationPainter.swift
//  jj-type
//
//  Shared drawing code for annotations. The overlay views call it with
//  scale == 1 (points) and the exporter calls it with the bitmap's pixel scale,
//  so what the user sees is exactly what gets saved / copied / pinned.
//
//  Everything is nonisolated: flattening a 5K bitmap must not run on the main
//  actor, and the painter only touches CGContext / CoreText (no AppKit).
//

import CoreGraphics
import CoreText
import Foundation

nonisolated enum AnnotationPainter {
    /// Draws `items` into `context`.
    ///
    /// - Parameters:
    ///   - origin: global point that maps to the context's (0, 0).
    ///   - scale: device pixels per point.
    ///   - canvasSize: size of the whole canvas in points (mosaic bounds).
    ///   - mosaic: pre-pixelated canvas used by mosaic strokes.
    ///   - clip: optional clip rect in device coordinates (before the transform).
    static func draw(_ items: [AnnotationItem],
                     in context: CGContext,
                     origin: CGPoint,
                     scale: CGFloat,
                     canvasSize: CGSize,
                     mosaic: CGImage?,
                     clip: CGRect? = nil) {
        guard !items.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }

        if let clip {
            context.clip(to: clip)
        }
        // Translate first, then scale: global point p lands on (p - origin) * scale.
        context.translateBy(x: -origin.x * scale, y: -origin.y * scale)
        context.scaleBy(x: scale, y: scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let canvas = CGRect(origin: origin, size: canvasSize)
        for item in items {
            draw(item, in: context, canvas: canvas, mosaic: mosaic)
        }
    }

    // MARK: - Single item

    private static func draw(_ item: AnnotationItem,
                             in context: CGContext,
                             canvas: CGRect,
                             mosaic: CGImage?) {
        switch item.tool {
        case .rectangle, .ellipse:
            let rect = item.shapeRect
            guard rect.width > 0.5, rect.height > 0.5 else { return }
            let path = item.tool == .rectangle
                ? CGPath(rect: rect, transform: nil)
                : CGPath(ellipseIn: rect, transform: nil)
            stroke(path, color: item.color, width: item.lineWidth, in: context)

        case .arrow:
            guard AnnotationMath.distance(from: item.start, to: item.end) > 1 else { return }
            stroke(arrowPath(item), color: item.color, width: item.lineWidth, in: context)

        case .pen:
            if item.path.count < 2 {
                fillDot(at: item.start,
                        radius: max(1.5, item.lineWidth / 2),
                        color: item.color.cgColor,
                        in: context)
            } else {
                stroke(polyline(item.path), color: item.color, width: item.lineWidth, in: context)
            }

        case .highlighter:
            let color = item.color.cgColor.copy(alpha: item.highlighterAlpha) ?? item.color.cgColor
            if item.path.count < 2 {
                fillDot(at: item.start, radius: item.lineWidth * 2, color: color, in: context)
            } else {
                context.saveGState()
                context.setStrokeColor(color)
                context.setLineWidth(item.lineWidth * 4)
                context.addPath(polyline(item.path))
                context.strokePath()
                context.restoreGState()
            }

        case .mosaic:
            guard let mosaic else { return }
            context.saveGState()
            if item.path.count < 2 {
                let radius = item.lineWidth * 2
                context.addEllipse(in: CGRect(x: item.start.x - radius,
                                              y: item.start.y - radius,
                                              width: radius * 2,
                                              height: radius * 2))
            } else {
                let strokePath = polyline(item.path).copy(strokingWithWidth: item.lineWidth * 4,
                                                          lineCap: .round,
                                                          lineJoin: .round,
                                                          miterLimit: 10)
                context.addPath(strokePath)
            }
            context.clip()
            context.interpolationQuality = .none
            context.draw(mosaic, in: canvas)
            context.restoreGState()

        case .text:
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            drawText(trimmed,
                     baseline: item.start,
                     size: item.textSize,
                     fontName: item.fontName,
                     color: item.color,
                     in: context)

        case .number:
            drawNumber(item, in: context)

        case .eraser:
            break
        }
    }

    // MARK: - Primitives

    private static func stroke(_ path: CGPath, color: AnnotationColor, width: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private static func fillDot(at point: CGPoint, radius: CGFloat, color: CGColor, in context: CGContext) {
        context.saveGState()
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                       width: radius * 2, height: radius * 2))
        context.restoreGState()
    }

    private static func polyline(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private static func arrowPath(_ item: AnnotationItem) -> CGPath {
        let path = CGMutablePath()
        path.move(to: item.start)
        path.addLine(to: item.end)

        let angle = atan2(item.end.y - item.start.y, item.end.x - item.start.x)
        let length = max(10, item.lineWidth * 3.5)
        let spread = CGFloat.pi / 7
        for side in [angle - spread, angle + spread] {
            path.move(to: item.end)
            path.addLine(to: CGPoint(x: item.end.x - cos(side) * length,
                                     y: item.end.y - sin(side) * length))
        }
        return path
    }

    private static func drawNumber(_ item: AnnotationItem, in context: CGContext) {
        let radius = item.numberRadius
        let circle = CGRect(x: item.start.x - radius,
                            y: item.start.y - radius,
                            width: radius * 2,
                            height: radius * 2)
        context.saveGState()
        context.setFillColor(item.color.cgColor)
        context.fillEllipse(in: circle)
        context.restoreGState()

        let label = "\(item.number)"
        let size = radius * 1.15
        drawText(label,
                 centeredIn: circle,
                 size: size,
                 fontName: "",
                 color: AnnotationColor(red: 1, green: 1, blue: 1),
                 in: context)
    }

    // MARK: - Text (CoreText keeps this usable off the main actor)

    /// Resolves the selected font; an unknown PostScript name falls back to the
    /// system UI font instead of a hard-coded Latin face.
    private static func makeFont(size: CGFloat, fontName: String) -> CTFont {
        if !fontName.isEmpty {
            return CTFontCreateWithName(fontName as CFString, size, nil)
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// Single-line width of `text`, measured through the exact font + CTLine path
    /// the painter draws with. Dirty-rect invalidation and the eraser's hit test
    /// use it, so no glyph is ever left behind (or missed) by an estimate.
    static func measuredWidth(_ text: String, size: CGFloat, fontName: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributes: [CFString: Any] = [kCTFontAttributeName: makeFont(size: size, fontName: fontName)]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return 0
        }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    }

    private static func makeLine(_ text: String,
                                 size: CGFloat,
                                 fontName: String,
                                 color: CGColor) -> CTLine? {
        let font = makeFont(size: size, fontName: fontName)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return nil
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    private static func drawText(_ text: String,
                                 baseline: CGPoint,
                                 size: CGFloat,
                                 fontName: String,
                                 color: AnnotationColor,
                                 in context: CGContext) {
        guard let line = makeLine(text, size: size, fontName: fontName, color: color.cgColor) else { return }
        context.saveGState()
        context.textPosition = baseline
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawText(_ text: String,
                                 centeredIn rect: CGRect,
                                 size: CGFloat,
                                 fontName: String,
                                 color: AnnotationColor,
                                 in context: CGContext) {
        guard let line = makeLine(text, size: size, fontName: fontName, color: color.cgColor) else { return }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.saveGState()
        context.textPosition = CGPoint(x: rect.midX - width / 2,
                                       y: rect.midY - (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Builds the blocky source used by mosaic strokes. One pass per canvas, cached
/// by the caller, so a stroke only ever clips and blits a tiny bitmap.
nonisolated enum MosaicGenerator {
    static func pixelated(_ image: CGImage, divisor: Int = 16) -> CGImage? {
        let width = max(1, image.width / max(1, divisor))
        let height = max(1, image.height / max(1, divisor))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Flattens annotations into the cropped screenshot (save / copy / pin).
nonisolated enum AnnotationRenderer {
    /// Returns `base` unchanged when there is nothing to draw.
    static func compose(_ base: CGImage,
                        selection: CGRect,
                        items: [AnnotationItem]) -> CGImage {
        guard !items.isEmpty, selection.width > 0, selection.height > 0 else { return base }

        let scale = CGFloat(base.width) / selection.width
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: base.width,
                                      height: base.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return base
        }
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))

        let mosaic = items.contains { $0.tool == .mosaic } ? MosaicGenerator.pixelated(base) : nil
        AnnotationPainter.draw(items,
                               in: context,
                               origin: selection.origin,
                               scale: scale,
                               canvasSize: selection.size,
                               mosaic: mosaic)
        return context.makeImage() ?? base
    }
}
