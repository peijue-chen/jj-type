//
//  make-icon.swift
//  jj-type — build-support
//
//  Renders the 1024×1024 app-icon master with CoreGraphics:
//  indigo→violet squircle + glossy top light + heavy "JJ" wordmark with a
//  warm-yellow text cursor (the "type" in JJType), plus hairline borders for
//  dark-mode pop. Deterministic — rerun to regenerate the master PNG, then
//  rebuild the .iconset/.icns (see README note in build-support).
//
//  Run from build-support/:  swift make-icon.swift
//

import AppKit

let side: CGFloat = 1024
let rect = CGRect(x: 0, y: 0, width: side, height: side)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(side), pixelsHigh: Int(side),
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("cannot allocate bitmap")
}
rep.size = NSSize(width: side, height: side)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("cannot create graphics context")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

let cg = ctx.cgContext

// -- Squircle canvas (macOS icon radius ≈ 22.37% of the side) ------------------
let radius = side * 0.2237
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
cg.addPath(squircle)
cg.clip()

// -- Base gradient: deep indigo → violet → azure -------------------------------
let colors = [
    CGColor(red: 0.23, green: 0.25, blue: 0.86, alpha: 1),   // indigo bottom-left
    CGColor(red: 0.45, green: 0.27, blue: 0.92, alpha: 1),   // violet
    CGColor(red: 0.29, green: 0.55, blue: 0.98, alpha: 1),   // azure top-right
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0.0, 0.55, 1.0])!
cg.drawLinearGradient(gradient,
                      start: CGPoint(x: 0, y: 0),
                      end: CGPoint(x: side, y: side),
                      options: [])

// -- Soft radial glow behind the wordmark --------------------------------------
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
                               CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                      locations: [0, 1])!
cg.drawRadialGradient(glow,
                      startCenter: CGPoint(x: side * 0.42, y: side * 0.55),
                      startRadius: 0,
                      endCenter: CGPoint(x: side * 0.42, y: side * 0.55),
                      endRadius: side * 0.55,
                      options: [])

// -- Top gloss (subtle liquid highlight) ---------------------------------------
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
                                CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                       locations: [0, 1])!
cg.drawLinearGradient(gloss,
                      start: CGPoint(x: 0, y: side),
                      end: CGPoint(x: 0, y: side * 0.42),
                      options: [])

// -- Wordmark: "JJ" + text cursor ----------------------------------------------
let wordmark = NSAttributedString(string: "JJ", attributes: [
    .font: NSFont.systemFont(ofSize: 430, weight: .heavy),
    .foregroundColor: NSColor.white,
])
let wordSize = wordmark.size()

let cursorWidth: CGFloat = 54
let cursorHeight = wordSize.height * 0.62
let gap: CGFloat = 44
let groupWidth = wordSize.width + gap + cursorWidth

let groupOriginX = (CGFloat(side) - groupWidth) / 2
let wordRect = CGRect(x: groupOriginX,
                      y: (CGFloat(side) - wordSize.height) / 2,
                      width: wordSize.width,
                      height: wordSize.height)

// Shared soft shadow so the wordmark reads as one group.
let shadow = NSShadow()
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.set()
wordmark.draw(in: wordRect)

// Cursor block (warm yellow, rounded ends, own warm glow).
let cursorRect = CGRect(x: wordRect.maxX + gap,
                        y: (CGFloat(side) - cursorHeight) / 2 + wordSize.height * 0.03,
                        width: cursorWidth,
                        height: cursorHeight)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 22,
             color: CGColor(red: 1, green: 0.84, blue: 0.1, alpha: 0.55))
cg.setFillColor(CGColor(red: 1, green: 0.84, blue: 0.04, alpha: 1))
let cursorPath = CGPath(roundedRect: cursorRect,
                        cornerWidth: cursorWidth / 2,
                        cornerHeight: cursorWidth / 2,
                        transform: nil)
cg.addPath(cursorPath)
cg.fillPath()
cg.restoreGState()

// -- Hairline inner border for dark-mode pop -----------------------------------
cg.addPath(squircle)
cg.setLineWidth(4)
cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
cg.strokePath()

NSGraphicsContext.restoreGraphicsState()

// -- Write the master PNG -------------------------------------------------------
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encoding failed")
}
let outURL = URL(fileURLWithPath: "icon_1024.png")
try! png.write(to: outURL)
print("wrote \(outURL.path)")
