---
type: Capability
title: Screen Capture — session, annotations, OCR, export
description: "The ⌘⇧2 capture flow: TCC-gated freeze of all displays, selection overlay, 9 annotation tools, OCR and QR recognition, export, and the strict window-level + nonisolated rules that keep it correct."
tags: [jjtype, screencapture, annotations, ocr, vision]
timestamp: "2026-11-05T10:30:00+08:00"
---

# Screen Capture

`jj-type/ScreenCapture/` (14 files) implements the full-screen capture flow triggered by ⌘⇧2. The session is orchestrated by `CaptureOverlayController`; annotations are owned by the controller and rendered through one shared painter so the overlay and the exported bitmap can never diverge.

## Session flow

1. **Permission gate** — `ScreenCapturePermission` wraps `CGPreflightScreenCaptureAccess` + `CGRequestScreenCaptureAccess`. If granted mid-session, macOS only applies it at process launch, so the guide's 「已授权，重启 JJType」 button calls `relaunch()` (spawn a new instance, terminate the current one). Never fall back to `CGWindowListCreateImage`.
2. **Resolve displays** — one `DisplayTarget` per `NSScreen` (displayID, frame, scale).
3. **Pins stay live** — `PinWindowController.setCaptureActive(true)` makes pins `ignoresMouseEvents` but *includes their window IDs* in the capture filter, so the frozen frame shows what the user sees.
4. **Freeze all displays** — `ScreenCaptureService.captureAllDisplays` (`nonisolated`, concurrent task group) uses `SCScreenshotManager.captureImage` + `SCContentFilter` excluding own windows except pins; results sorted back to `NSScreen` order.
5. **Window snapshot** — `WindowSnapshot` enumerates `CGWindowListCopyWindowInfo`, converting CG top-left → AppKit bottom-left (`y = primaryMaxY - cgRect.maxY`) for hover-to-select highlight.
6. **Overlay** — one borderless non-activating `CaptureOverlayWindow` per display at `.screenSaverWindow`, each drawing the frozen frame, a 45%-black dim mask with a punched selection hole, and the window-hover highlight. **No magnifier by design** (read as a dark blob chasing the cursor).
7. **Selection** — drag (global bottom-left coordinates, min 3pt), click-a-window, arrow-key nudge (±1pt, ±10 with Shift). After mouse-up the toolbar appears.

## Window levels & edits

The level ladder (overlay +0, pins +1, toolbar +2, hints +3, toast +4) is a global invariant enforced across the app — see [Architecture overview](/openwiki/architecture/overview.md) for the table and the pop-up menu level workaround.

**Selection locks once annotated**: with any annotation present, move/resize/nudge are disabled ("Annotations lock the frame") because relocating would tear the strokes loose. Right-click on the overlay always cancels the session.

**Annotation model** (`AnnotationTool.swift`): `AnnotationItem` stores **global** AppKit coordinates (a stroke can span displays); freehand tools collect `path: [CGPoint]`, shapes use `start`/`end`; each item snapshots `color`, `lineWidth` (3 widths), `alpha` (highlighter clamped 0.05–1.0), and text items carry their own `fontName`/`fontSize` (independent from stroke widths). Undo/redo snapshots history bounded at 64 entries. Eraser hit-tests the topmost (last) item: outline-only for rect/ellipse (can't swallow a box whole), bounded box for text/number, segment distance for freehand.

**Text tool**: inline `NSTextField` in the overlay with transparent background, no border, colored caret; Enter commits, Esc drops, Tab commits; Chinese IME candidates preserved. The field editor is shared app-wide, so `applyStyleToTextEditor` pushes every change into the live editor and teardown must restore `drawsBackground`/`backgroundColor`/`insertionPointColor`. While the editor is first responder, `CaptureOverlayWindow.performKeyEquivalent` bails out — otherwise ⌘C would copy the screenshot and silently drop the half-typed annotation.

**Build-invariant rules** (from AGENTS.md): the overlay session owns the selection in AppKit *global* coordinates and converts only at the capture boundary; freeze/crop/export stay `nonisolated`; every repaint is a dirty rect (`setNeedsDisplay(_:)`), never a whole 5K overlay; mosaic pixelation runs in a detached task; a double-click inside the selection commits pending text, rolls back the click's own dot, and does `copyAndSave` "keep the shot".

## Toolbar

`CaptureToolbarController` floats next to the selection: 9 annotation tools, undo/redo, 6-colour fixed palette, 3 widths, tool option row (font+size for text, alpha for highlighter), recognize / pin / save / copy / close, own hover hints, edge avoidance. Every action is never silent (`CaptureToast`); only real errors use `NSAlert`. A pending inline text edit is committed first; a half-drawn stroke is dropped; a double click never dismisses a pin (right-click menu offers copy/save/close).

## Export

`CaptureExporter` writes PNG/JPEG to `~/Pictures/JJType/JJType-yyyyMMdd-HHmmss.<ext>` (one-second granularity, never overwrites; JPEG quality 0.9) and/or copies an `NSImage` with pointSize metadata so the pasted bitmap matches the on-screen size. Save failures distinguish the two paths ("已复制，但保存截图失败").

## OCR & QR recognition

`TextRecognizer` (Vision, `nonisolated`, detached): revision-3, `.accurate`, languages zh-Hans/zh-Hant/en-US filtered by runtime support; small crops (≤640 px shortest side) upscaled up to 3×; duplicate fragments (>70% overlap) deduped by confidence; rows clustered by vertical proximity (60% tolerance) with CJK-aware spacing — rows are **not** merged into paragraphs (corrupts form labels). OCR runs on the *unannotated* crop; text goes straight to the pasteboard + toast (no result panel).

QR recognition uses `QRService.recognizeQR` on the **composited** selection (unlike OCR's untouched base); single http(s) payload additionally offers 打开网址.