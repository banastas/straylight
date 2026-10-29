import AppKit
import StraylightKit

/// Draws the status item as one image (PRD §6.6, §7.4): the RTT of the target
/// shown, as text, a trace or both, and the verdict mark. With text, the mark
/// sits at the end of the `RTT` row, which has room to spare; otherwise it has
/// a column of its own. The width depends only on the style and target, never
/// on the values, so it doesn't jump.
///
/// The canvas and glyph-cell text drawing are flatline's (PRD §13).
@MainActor
enum MenuBarRenderer {
    enum Piece: Sendable, Equatable {
        /// `RTT` over `23ms`; the caption is `TCP` in TCP mode. The mark goes
        /// at the end of the caption row.
        case stacked(caption: String, value: String, mark: Mark)
        /// Router over internet, for the both-targets view.
        case pair(top: String, bottom: String)
        /// Trace heights in 0...1, right-aligned: a new trace grows from the right.
        case trace([Double])
        /// Router over internet, half height each.
        case traces(top: [Double], bottom: [Double])
        case mark(Mark)
    }

    enum Mark: Sendable, Equatable {
        case none, problem, down, paused

        init(_ text: String) {
            self = switch text {
            case "!": .problem
            case "×": .down
            case "‖": .paused
            default: .none
            }
        }
    }

    static let traceWidth = CGFloat(AppModel.traceLength)
    static let gap: CGFloat = 4
    static let markWidth: CGFloat = 6
    /// Trace scale floors, in ms: router RTTs are small, internet ones larger.
    static let routerTraceFloor = 2.0
    static let internetTraceFloor = 10.0

    /// Everything that determines the pixels. Equal layouts render identical
    /// images, so the status item can skip redraws when nothing visible changed.
    struct Layout: Equatable {
        var pieces: [Piece]
        var dimmed: Bool
    }

    static func layout(model: AppModel, preferences: Preferences) -> Layout {
        let snapshot = model.snapshot
        func value(_ role: TargetRole) -> String {
            guard let target = snapshot[role], target.status != .warmingUp, target.status.measuredProtocol != nil,
                  target.state != .down else { return "—" }
            return MenuBarText.rtt(target.metrics.latest)
        }
        /// Numbers right-aligned so digits don't shift; a lone `—` centered.
        func padded(_ text: String) -> String {
            text == "—" ? text : text.leftPadded(to: widest)
        }
        func trace(_ role: TargetRole) -> [Double] {
            MenuBarText.trace(model.menuBarTrace(role), floor: role == .router ? routerTraceFloor : internetTraceFloor)
        }

        var pieces: [Piece] = []
        let style = preferences.displayStyle
        let mark = Mark(MenuBarText.mark(for: snapshot.verdict, paused: model.isPaused))
        switch preferences.menuBarTarget {
        case .internet, .router:
            let role: TargetRole = preferences.menuBarTarget == .router ? .router : .internet(0)
            if style != .text { pieces.append(.trace(trace(role))) }
            if style != .trace {
                pieces.append(.stacked(caption: snapshot[role]?.status == .tcp ? "TCP" : "RTT", value: padded(value(role)), mark: mark))
            } else {
                pieces.append(.mark(mark))
            }
        case .both:
            if style != .text { pieces.append(.traces(top: trace(.router), bottom: trace(.internet(0)))) }
            if style != .trace {
                pieces.append(.pair(top: "R " + value(.router).leftPadded(to: widest), bottom: "I " + value(.internet(0)).leftPadded(to: widest)))
            }
            // Both rows are full, so the mark keeps its own column.
            pieces.append(.mark(mark))
        }
        return Layout(pieces: pieces, dimmed: model.isPaused)
    }

    private static let widest = MenuBarText.widestRTT.count

    /// Renders `layout` at `scale` pixels per point, in the menu bar's own label
    /// color (resolved for `appearance`) so it can go straight into a layer.
    ///
    /// Plain Core Graphics into canvases kept between ticks. Rasterizing here,
    /// rather than handing AppKit a drawing-handler image, also avoids a CoreText
    /// crash in the status bar's stylized drawing path on macOS 27.
    ///
    /// `colorSpace` should be the status item window's: Core Animation color
    /// converts every new image drawn in any other space when it commits it.
    static func image(for layout: Layout, appearance: NSAppearance, scale: CGFloat, colorSpace: CGColorSpace) -> CGImage? {
        if colorSpace != canvasColorSpace {
            canvasColorSpace = colorSpace
            canvases = []
            glyphCells = [:]
        }
        let pieces = layout.pieces
        let size = CGSize(
            width: max(1, ceil(pieces.map(width(of:)).reduce(0, +) + gap * CGFloat(max(0, pieces.count - 1)))),
            height: NSStatusBar.system.thickness
        )
        guard let canvas = canvas(size: size, scale: scale) else { return nil }
        let context = canvas.context
        let ink = colors(for: appearance, scale: scale, dimmed: layout.dimmed)

        canvas.clear()
        drawingCanvas = canvas
        defer { drawingCanvas = nil }
        var x: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            if index > 0 { x += gap }
            draw(piece, at: x, height: size.height, ink: ink, in: context)
            x += width(of: piece)
        }
        return canvas.image()
    }

    // MARK: - VoiceOver

    /// For example "Good. Internet 23 milliseconds, jitter 4, loss 0 percent. Router 3 milliseconds."
    static func accessibilityLabel(model: AppModel) -> String {
        let snapshot = model.snapshot
        if let until = model.pausedUntil {
            return String(localized: "Paused until \(until.formatted(date: .omitted, time: .shortened)).")
        }
        var sentences = [snapshot.verdict.title + "."]
        if let internet = snapshot[.internet(0)], internet.status != .warmingUp, let rtt = internet.metrics.latest, internet.state != .down {
            let jitter = spoken(internet.metrics.jitter ?? 0)
            let loss = Int(internet.metrics.lossPercent.rounded())
            sentences.append(String(localized: "Internet \(spoken(rtt)) milliseconds, jitter \(jitter), loss \(loss) percent."))
        }
        if let router = snapshot[.router], router.status == .icmp, let rtt = router.metrics.latest, router.state != .down {
            sentences.append(String(localized: "Router \(spoken(rtt)) milliseconds."))
        }
        return sentences.joined(separator: " ")
    }

    /// One decimal under 10 ms, whole milliseconds above.
    private static func spoken(_ milliseconds: Double) -> String {
        milliseconds < 9.95 ? milliseconds.formatted(.number.precision(.fractionLength(1))) : milliseconds.formatted(.number.precision(.fractionLength(0)))
    }

    // MARK: - Layout

    private static let stackedWidth = ceil(max(textWidth("TCP", font: captionFont), textWidth(MenuBarText.widestRTT, font: valueFont)))
    private static let pairWidth = textWidth("R " + MenuBarText.widestRTT, font: pairFont)

    private static func width(of piece: Piece) -> CGFloat {
        switch piece {
        case .stacked: stackedWidth
        case .pair: pairWidth
        case .trace, .traces: traceWidth
        case .mark: markWidth
        }
    }

    private static var widthCache: [String: CGFloat] = [:]

    private static func textWidth(_ string: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)|\(string)"
        if let cached = widthCache[key] { return cached }
        let width = ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width)
        widthCache[key] = width
        return width
    }

    // MARK: - Drawing

    private static let captionFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
    private static let valueFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private static let pairFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)

    /// A bitmap drawn into on alternate ticks. Its CTM is flipped so y grows
    /// downward, like AppKit views. straylight owns the pixels so text can be
    /// copied straight in, and images are made from the same memory without a
    /// copy. Two canvases alternate: Core Animation copies an image's pixels
    /// when it commits the layer, so a canvas is free again two ticks later.
    private final class Canvas {
        let context: CGContext
        let buffer: UnsafeMutableRawPointer
        /// Owns `buffer`: frees it once the canvas and every image made from
        /// it are gone, so a resize can't free pixels an image still uses.
        let provider: CGDataProvider

        init?(pixelWidth: Int, pixelHeight: Int, scale: CGFloat, height: CGFloat, colorSpace: CGColorSpace) {
            let bytesPerRow = pixelWidth * 4
            let size = bytesPerRow * pixelHeight
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: size, releaseData: { _, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
            }) else {
                buffer.deallocate()
                return nil
            }
            guard let context = CGContext(
                data: buffer, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: 0, y: -height)
            self.context = context
            self.buffer = buffer
            self.provider = provider
        }

        func clear() {
            memset(buffer, 0, context.bytesPerRow * context.height)
        }

        /// Wraps the current pixels without copying them.
        func image() -> CGImage? {
            CGImage(
                width: context.width, height: context.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: context.bytesPerRow, space: context.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }

    private static var canvases: [Canvas] = []
    private static var canvasColorSpace = CGColorSpaceCreateDeviceRGB()
    private static var nextCanvas = 0
    /// The canvas being drawn this tick; text is copied into its buffer.
    private static var drawingCanvas: Canvas?

    private static func canvas(size: CGSize, scale: CGFloat) -> Canvas? {
        let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)
        if canvases.first.map({ $0.context.width != pixelWidth || $0.context.height != pixelHeight }) ?? true {
            canvases = (0..<2).compactMap { _ in Canvas(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, height: size.height, colorSpace: canvasColorSpace) }
            guard canvases.count == 2 else { canvases = []; return nil }
        }
        nextCanvas = (nextCanvas + 1) % canvases.count
        return canvases[nextCanvas]
    }

    /// Label colors resolved for one appearance, plus that appearance's text images.
    private struct Ink {
        var key: String
        var text: CGColor
        var caption: CGColor
        var baseline: CGColor
        var secondary: CGColor
        /// Never dimmed: the pause mark is what says why everything else is.
        var mark: CGColor
    }

    private static var currentInk: Ink?

    /// Paused, everything but the mark is drawn at this opacity.
    private static let dimmedAlpha: CGFloat = 0.4

    private static func colors(for appearance: NSAppearance, scale: CGFloat, dimmed: Bool) -> Ink {
        let key = "\(appearance.name.rawValue)@\(scale)\(dimmed ? "-dimmed" : "")"
        if let currentInk, currentInk.key == key { return currentInk }
        var ink: Ink!
        appearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor
            let alpha = dimmed ? dimmedAlpha : 1
            ink = Ink(
                key: key,
                text: label.withAlphaComponent(alpha).cgColor,
                caption: label.withAlphaComponent(0.7 * alpha).cgColor,
                baseline: label.withAlphaComponent(0.25 * alpha).cgColor,
                secondary: label.withAlphaComponent(0.45 * alpha).cgColor,
                mark: label.cgColor
            )
        }
        currentInk = ink
        glyphCells.removeAll()
        return ink
    }

    private static func draw(_ piece: Piece, at x: CGFloat, height: CGFloat, ink: Ink, in context: CGContext) {
        let mid = height / 2
        switch piece {
        case let .stacked(caption, value, mark):
            drawText(caption, font: captionFont, color: ink.caption, centeredIn: stackedWidth, x: x, y: mid - 11, in: context)
            drawText(value, font: valueFont, color: ink.text, centeredIn: stackedWidth, x: x, y: mid - 2.5, in: context)
            // Over the value's unit, level with the caption.
            drawMark(mark, centerX: x + stackedWidth - 2.5, mid: mid - 6.5, scale: captionMarkScale, color: ink.mark, context: context)

        case let .pair(top, bottom):
            drawText(top, font: pairFont, color: ink.text, centeredIn: pairWidth, x: x, y: mid - 11, in: context)
            drawText(bottom, font: pairFont, color: ink.text, centeredIn: pairWidth, x: x, y: mid - 0.5, in: context)

        case let .trace(values):
            drawTrace(values, in: CGRect(x: x, y: mid - 8, width: traceWidth, height: 16), ink: ink, context: context)

        case let .traces(top, bottom):
            drawTrace(top, in: CGRect(x: x, y: mid - 8, width: traceWidth, height: 7), ink: ink, context: context)
            drawTrace(bottom, in: CGRect(x: x, y: mid + 1, width: traceWidth, height: 7), ink: ink, context: context)

        case let .mark(mark):
            drawMark(mark, centerX: x + markWidth / 2, mid: mid, scale: 1, color: ink.mark, context: context)
        }
    }

    private static func drawTrace(_ values: [Double], in rect: CGRect, ink: Ink, context: CGContext) {
        context.setFillColor(ink.baseline)
        context.fill(CGRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5))
        guard values.count > 1 else { return }
        // One point per pixel, newest at the right edge.
        let step = rect.width / (traceWidth - 1)
        let start = rect.maxX - step * CGFloat(values.count - 1)
        let points = values.enumerated().map { index, value in
            CGPoint(x: start + CGFloat(index) * step, y: rect.maxY - 0.75 - CGFloat(max(0, min(1, value))) * (rect.height - 1.5))
        }
        context.beginPath()
        context.addLines(between: points)
        context.setLineWidth(1.25)
        context.setLineJoin(.round)
        context.setStrokeColor(ink.text)
        context.strokePath()
    }

    /// The mark's size in the caption row, which is 8 pt type.
    private static let captionMarkScale: CGFloat = 0.75

    /// Drawn as shapes, not text, so they never depend on font fallback.
    /// `scale` 1 is the full-height mark of its own column.
    private static func drawMark(_ mark: Mark, centerX: CGFloat, mid: CGFloat, scale: CGFloat, color: CGColor, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        // Scaled about the mark's center; the stroke stays 1.5 pt for legibility.
        context.translateBy(x: centerX, y: mid)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -centerX, y: -mid)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(1.5 / scale)
        context.setLineCap(.round)
        context.beginPath()
        switch mark {
        case .none:
            return
        case .problem:
            context.move(to: CGPoint(x: centerX, y: mid - 5.5))
            context.addLine(to: CGPoint(x: centerX, y: mid + 1.5))
            context.strokePath()
            context.fillEllipse(in: CGRect(x: centerX - 1, y: mid + 3.5, width: 2, height: 2))
        case .down:
            context.move(to: CGPoint(x: centerX - 2.5, y: mid - 2.5))
            context.addLine(to: CGPoint(x: centerX + 2.5, y: mid + 2.5))
            context.move(to: CGPoint(x: centerX + 2.5, y: mid - 2.5))
            context.addLine(to: CGPoint(x: centerX - 2.5, y: mid + 2.5))
            context.strokePath()
        case .paused:
            for dx in [-1.5, 1.5] {
                context.move(to: CGPoint(x: centerX + dx, y: mid - 4.5))
                context.addLine(to: CGPoint(x: centerX + dx, y: mid + 4.5))
            }
            context.strokePath()
        }
    }

    // MARK: Text
    //
    // Every menu bar font is monospaced, so a string is a row of equal cells.
    // Each character is rasterized once per font, color and scale; drawing a
    // string copies those cells into the canvas buffer. About 30 distinct
    // characters cover everything straylight shows, so after the first few ticks
    // drawing text never touches CoreText. (Caching whole strings missed on most
    // network rates, and each miss cost ~140 µs on an idle, clocked-down core.)

    private struct GlyphKey: Hashable {
        let fontSize: CGFloat
        let alpha: CGFloat
        let character: Character
    }

    /// Premultiplied RGBA pixels, top row first, `padding` px of margin each side
    /// so glyphs that overhang their advance aren't clipped. `ink` is the
    /// bounding box of non-transparent pixels; only that part is copied.
    private struct GlyphCell {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let ink: (columns: Range<Int>, rows: Range<Int>)
    }

    private static let padding = 2
    private static var glyphCells: [GlyphKey: GlyphCell] = [:]
    private static var advances: [CGFloat: CGFloat] = [:]

    private static func advance(of font: NSFont) -> CGFloat {
        if let cached = advances[font.pointSize] { return cached }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "0", attributes: [.font: font]))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        advances[font.pointSize] = advance
        return advance
    }

    /// Draws `string` with its line box's top edge at `y`, centered in `width`.
    private static func drawText(_ string: String, font: NSFont, color: CGColor, centeredIn width: CGFloat, x: CGFloat, y: CGFloat, in context: CGContext) {
        guard let buffer = drawingCanvas?.buffer else { return }
        let scale = context.ctm.a
        let advance = advance(of: font)
        let characters = Array(string)
        let start = x + (width - advance * CGFloat(characters.count)) / 2
        let top = Int((y * scale).rounded())
        let canvasWidth = context.width, canvasHeight = context.height, bytesPerRow = context.bytesPerRow
        let pixels = buffer.assumingMemoryBound(to: UInt8.self)

        for (index, character) in characters.enumerated() where character != " " {
            let key = GlyphKey(fontSize: font.pointSize, alpha: color.alpha, character: character)
            let cell: GlyphCell
            if let cached = glyphCells[key] {
                cell = cached
            } else {
                guard let rendered = renderGlyph(character, font: font, color: color, advance: advance, scale: scale) else { continue }
                glyphCells[key] = rendered
                cell = rendered
            }
            let left = Int(((start + advance * CGFloat(index)) * scale).rounded()) - padding
            let firstColumn = max(cell.ink.columns.lowerBound, -left)
            let lastColumn = min(cell.ink.columns.upperBound, canvasWidth - left)
            let firstRow = max(cell.ink.rows.lowerBound, -top)
            let lastRow = min(cell.ink.rows.upperBound, canvasHeight - top)
            guard firstColumn < lastColumn, firstRow < lastRow else { continue }
            // Composite with a per-byte max: neighboring cells can overlap at
            // their edges, and two same-colored glyphs over a cleared canvas
            // merge correctly that way. 16 bytes at a time, then the remainder.
            let spanBytes = (lastColumn - firstColumn) * 4
            cell.pixels.withUnsafeBytes { source in
                for row in firstRow..<lastRow {
                    let destination = UnsafeMutableRawPointer(pixels + (top + row) * bytesPerRow + (left + firstColumn) * 4)
                    let sourceRow = source.baseAddress! + (row * cell.width + firstColumn) * 4
                    var byte = 0
                    while byte + 16 <= spanBytes {
                        let merged = pointwiseMax(
                            destination.loadUnaligned(fromByteOffset: byte, as: SIMD16<UInt8>.self),
                            sourceRow.loadUnaligned(fromByteOffset: byte, as: SIMD16<UInt8>.self)
                        )
                        destination.storeBytes(of: merged, toByteOffset: byte, as: SIMD16<UInt8>.self)
                        byte += 16
                    }
                    while byte < spanBytes {
                        let value = sourceRow.load(fromByteOffset: byte, as: UInt8.self)
                        if value > destination.load(fromByteOffset: byte, as: UInt8.self) {
                            destination.storeBytes(of: value, toByteOffset: byte, as: UInt8.self)
                        }
                        byte += 1
                    }
                }
            }
        }
    }

    /// Rasterizes one character into a cell whose top edge is the font's line
    /// top, matching where NSString drawing places text.
    private static func renderGlyph(_ character: Character, font: NSFont, color: CGColor, advance: CGFloat, scale: CGFloat) -> GlyphCell? {
        let width = Int(ceil(advance * scale)) + 2 * padding
        let lineHeight = font.ascender - font.descender + font.leading
        let height = Int(ceil(lineHeight * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: canvasColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        let attributed = NSAttributedString(string: String(character), attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(color)
        context.textPosition = CGPoint(x: CGFloat(padding) / scale, y: CGFloat(height) / scale - font.ascender)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        // Ink bounds: rows and columns with any non-zero alpha.
        var minColumn = width, maxColumn = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for column in 0..<width where bytes[(row * width + column) * 4 + 3] != 0 {
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        let ink = maxColumn < 0 ? (0..<0, 0..<0) : (minColumn..<maxColumn + 1, minRow..<maxRow + 1)
        return GlyphCell(pixels: bytes, width: width, height: height, ink: ink)
    }
}
