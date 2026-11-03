//
//  AnnotationTool.swift
//  jj-type
//
//  Model for the Snipaste-style annotation toolbar: the 9 tools, the fixed
//  6-colour palette, 3 stroke widths and the annotation items themselves.
//
//  Every coordinate stored here is an AppKit *global* point (bottom-left
//  origin), exactly like the capture session, so a stroke can start on one
//  display and end on another and only gets rebased when it is flattened.
//

import CoreGraphics
import Foundation

nonisolated enum AnnotationTool: String, CaseIterable, Sendable {
    case rectangle
    case ellipse
    case arrow
    case pen
    case highlighter
    case mosaic
    case text
    case number
    case eraser

    /// Freehand tools collect a path instead of a start/end pair.
    var usesFreehand: Bool {
        switch self {
        case .pen, .highlighter, .mosaic, .eraser: return true
        case .rectangle, .ellipse, .arrow, .text, .number: return false
        }
    }

    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .text: return "textformat"
        case .number: return "number.circle"
        case .eraser: return "eraser"
        }
    }

    var displayName: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlighter: return "马克笔"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        case .number: return "序号"
        case .eraser: return "橡皮"
        }
    }

    /// Hover description shown by the toolbar (the panel never becomes key, so
    /// the system tooltip would not appear reliably).
    var hint: String {
        switch self {
        case .rectangle: return "矩形 — 拖拽画出方框"
        case .ellipse: return "椭圆 — 拖拽画出圆形"
        case .arrow: return "箭头 — 从起点拖到终点"
        case .pen: return "画笔 — 按住自由绘制"
        case .highlighter: return "马克笔 — 半透明高亮，可调透明度"
        case .mosaic: return "马赛克 — 涂抹遮挡敏感信息"
        case .text: return "文字 — 点击输入，可调字体与字号"
        case .number: return "序号 — 点击放置递增编号"
        case .eraser: return "橡皮 — 点击擦除单个标注"
        }
    }
}

/// Text font choice for the text tool. `name` is a PostScript name; an empty
/// name means the localised system UI font (correct for both CJK and Latin).
nonisolated struct AnnotationFont: Sendable, Equatable {
    let name: String
    let displayName: String

    static let system = AnnotationFont(name: "", displayName: "系统")

    static let options: [AnnotationFont] = [
        .system,
        AnnotationFont(name: "PingFangSC-Regular", displayName: "苹方"),
        AnnotationFont(name: "STSongti-SC-Regular", displayName: "宋体"),
        AnnotationFont(name: "HelveticaNeue", displayName: "Helvetica"),
    ]
}

/// Device-colour wrapper so the painter can stay nonisolated (NSColor is not
/// sendable); AppKit colours are created at the drawing site.
nonisolated struct AnnotationColor: Sendable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// Fixed 6-colour palette (decision #10: no colour picker).
    static let palette: [AnnotationColor] = [
        AnnotationColor(red: 1.00, green: 0.23, blue: 0.19), // red
        AnnotationColor(red: 1.00, green: 0.79, blue: 0.16), // yellow
        AnnotationColor(red: 0.20, green: 0.78, blue: 0.35), // green
        AnnotationColor(red: 0.04, green: 0.52, blue: 1.00), // blue
        AnnotationColor(red: 1.00, green: 1.00, blue: 1.00), // white
        AnnotationColor(red: 0.11, green: 0.11, blue: 0.12), // near black
    ]
}

nonisolated enum AnnotationPalette {
    /// 3 widths (decision #10).
    static let widths: [CGFloat] = [2, 4, 7]
    static let widthNames = ["细", "中", "粗"]

    /// Text sizes in points — independent from the stroke widths.
    static let fontSizes: [CGFloat] = [14, 20, 28, 40]
    static let fontSizeNames = ["小", "中", "大", "特大"]

    /// Highlighter alpha range: near-transparent up to fully opaque.
    static let alphaRange: ClosedRange<CGFloat> = 0.05...1
}

nonisolated struct AnnotationStyle: Sendable, Equatable {
    var colorIndex = 0
    var widthIndex = 1
    var fontIndex = 0
    var fontSizeIndex = 1
    var highlighterAlpha: CGFloat = 0.35

    var color: AnnotationColor {
        let palette = AnnotationColor.palette
        return palette[min(max(colorIndex, 0), palette.count - 1)]
    }

    var lineWidth: CGFloat {
        let widths = AnnotationPalette.widths
        return widths[min(max(widthIndex, 0), widths.count - 1)]
    }

    var font: AnnotationFont {
        let fonts = AnnotationFont.options
        return fonts[min(max(fontIndex, 0), fonts.count - 1)]
    }

    var fontSize: CGFloat {
        let sizes = AnnotationPalette.fontSizes
        return sizes[min(max(fontSizeIndex, 0), sizes.count - 1)]
    }
}

nonisolated struct AnnotationItem: Sendable, Identifiable {
    var id: Int
    let tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var path: [CGPoint]
    var color: AnnotationColor
    var lineWidth: CGFloat
    var text: String
    var number: Int
    /// Text tool only: PostScript font name (empty = system font).
    var fontName: String = ""
    /// Text tool only: font size in points (independent from `lineWidth`).
    var fontSize: CGFloat = 20
    /// Highlighter only: stroke alpha (the marker never fully hides the text).
    var alpha: CGFloat = 0.35

    init(id: Int = 0,
         tool: AnnotationTool,
         start: CGPoint,
         end: CGPoint = .zero,
         path: [CGPoint] = [],
         color: AnnotationColor,
         lineWidth: CGFloat,
         text: String = "",
         number: Int = 0,
         fontName: String = "",
         fontSize: CGFloat = 20,
         alpha: CGFloat = 0.35) {
        self.id = id
        self.tool = tool
        self.start = start
        self.end = end
        self.path = path
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.number = number
        self.fontName = fontName
        self.fontSize = fontSize
        self.alpha = alpha
    }

    var textSize: CGFloat { max(9, fontSize) }

    /// Highlighter alpha clamped to a range that stays see-through.
    var highlighterAlpha: CGFloat {
        min(max(alpha, AnnotationPalette.alphaRange.lowerBound),
            AnnotationPalette.alphaRange.upperBound)
    }

    var numberRadius: CGFloat { max(9, lineWidth * 2.4) }

    /// Whether the item is worth committing. A click, or a perfectly flat box
    /// drag, would otherwise create an annotation that paints nothing while
    /// still locking the frame and burning an undo step.
    var isMeaningful: Bool {
        switch tool {
        case .rectangle, .ellipse:
            return shapeRect.width >= 2 && shapeRect.height >= 2
        case .arrow:
            return AnnotationMath.distance(from: start, to: end) > 2
        case .pen, .highlighter, .mosaic, .text, .number, .eraser:
            return true
        }
    }

    /// Rect spanned by start/end, independent of the drag direction.
    var shapeRect: CGRect {
        CGRect(x: min(start.x, end.x),
               y: min(start.y, end.y),
               width: abs(end.x - start.x),
               height: abs(end.y - start.y))
    }

    /// Global bounding box including stroke thickness (used for partial redraw).
    var bounds: CGRect {
        switch tool {
        case .rectangle, .ellipse, .arrow:
            return shapeRect.insetBy(dx: -lineWidth * 3, dy: -lineWidth * 3)
        case .pen, .highlighter, .mosaic:
            guard let first = path.first else {
                return CGRect(origin: start, size: .zero).insetBy(dx: -16, dy: -16)
            }
            var rect = CGRect(origin: first, size: .zero)
            for point in path.dropFirst() {
                rect = rect.union(CGRect(origin: point, size: .zero))
            }
            return rect.insetBy(dx: -lineWidth * 4, dy: -lineWidth * 4)
        case .text:
            let size = textSize
            // Measured, not estimated: CJK glyphs are a full em wide, so the old
            // `count * 0.64` guess left the right half of a Chinese label out of
            // the dirty rect (ghost pixels after undo / erase) and unreachable
            // for the eraser.
            let width = max(size * 0.5,
                            AnnotationPainter.measuredWidth(text, size: size, fontName: fontName))
            return CGRect(x: start.x, y: start.y - size * 0.3,
                          width: width, height: size * 1.5)
                .insetBy(dx: -6, dy: -6)
        case .number:
            return CGRect(x: start.x - numberRadius,
                          y: start.y - numberRadius,
                          width: numberRadius * 2,
                          height: numberRadius * 2)
                .insetBy(dx: -4, dy: -4)
        case .eraser:
            return .zero
        }
    }

    /// Eraser hit test in global coordinates.
    func hitTest(_ point: CGPoint) -> Bool {
        switch tool {
        case .text, .number:
            return bounds.contains(point)
        case .rectangle, .ellipse:
            // Only the outline counts, so the eraser cannot swallow a whole box.
            let outer = shapeRect.insetBy(dx: -(lineWidth + 4), dy: -(lineWidth + 4))
            let inner = shapeRect.insetBy(dx: lineWidth + 4, dy: lineWidth + 4)
            guard outer.contains(point) else { return false }
            return !(inner.width > 0 && inner.height > 0 && inner.contains(point))
        case .arrow, .pen, .highlighter, .mosaic:
            let tolerance = max(6, lineWidth * 2.5)
            guard path.count >= 2 else {
                return AnnotationMath.distance(from: start, to: point) <= tolerance
            }
            for index in 1..<path.count {
                if AnnotationMath.distance(from: path[index - 1], to: path[index], point: point) <= tolerance {
                    return true
                }
            }
            return false
        case .eraser:
            return false
        }
    }
}

nonisolated enum AnnotationMath {
    /// Shortest distance between `point` and the segment `a`–`b`.
    static func distance(from a: CGPoint, to b: CGPoint, point: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(from: a, to: point) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = Swift.min(Swift.max(t, 0), 1)
        return distance(from: CGPoint(x: a.x + t * dx, y: a.y + t * dy), to: point)
    }

    static func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
