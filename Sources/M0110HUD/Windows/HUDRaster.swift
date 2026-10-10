import Foundation

// Software-drawn HUD. GDI cannot antialias shapes or use alpha, so shapes come from signed
// distances. Nothing here calls Windows, so tools/win-hud-preview.sh can draw it on a Mac.

/// sRGB with straight alpha, each part 0...1.
struct RGBA: Equatable {
    var r, g, b, a: Float

    init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(gray: Float, _ a: Float = 1) { self.init(gray, gray, gray, a) }

    func alpha(_ factor: Float) -> RGBA { RGBA(r, g, b, a * factor) }
}

/// Coverage 0-255, `width` x `height`, top-down.
struct TextMask {
    var width: Int
    var height: Int
    var coverage: [UInt8]
}

protocol TextRasterizer {
    /// `size` is the em height in pixels. `weight` is CSS-style (400 regular, 600 semibold).
    /// Text wider than `maxWidth` ends in an ellipsis.
    func render(_ text: String, size: Int, weight: Int, maxWidth: Int) -> TextMask
    func icon(_ codepoint: UInt32, size: Int) -> TextMask?
}

/// Premultiplied RGBA, one Float per channel.
struct Canvas {
    let width: Int
    let height: Int
    private(set) var pixels: [Float]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [Float](repeating: 0, count: width * height * 4)
    }

    @inline(__always)
    mutating func blend(_ x: Int, _ y: Int, _ color: RGBA, coverage: Float) {
        let a = color.a * coverage
        guard a > 0, x >= 0, y >= 0, x < width, y < height else { return }
        let i = (y * width + x) * 4
        let keep = 1 - a
        pixels[i] = color.r * a + pixels[i] * keep
        pixels[i + 1] = color.g * a + pixels[i + 1] * keep
        pixels[i + 2] = color.b * a + pixels[i + 2] * keep
        pixels[i + 3] = a + pixels[i + 3] * keep
    }

    /// Fills a shape given as a signed distance in pixels (negative inside), with 1 px of antialiasing.
    mutating func fill(_ color: RGBA, in bounds: (x0: Float, y0: Float, x1: Float, y1: Float),
                       _ distance: (Float, Float) -> Float) {
        let x0 = max(0, Int(bounds.x0.rounded(.down)) - 1), x1 = min(width - 1, Int(bounds.x1.rounded(.up)) + 1)
        let y0 = max(0, Int(bounds.y0.rounded(.down)) - 1), y1 = min(height - 1, Int(bounds.y1.rounded(.up)) + 1)
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            let py = Float(y) + 0.5
            for x in x0...x1 {
                let d = distance(Float(x) + 0.5, py)
                let coverage = min(max(0.5 - d, 0), 1)
                if coverage > 0 { blend(x, y, color, coverage: coverage) }
            }
        }
    }

    mutating func draw(_ mask: TextMask, at x: Int, _ y: Int, _ color: RGBA) {
        for my in 0..<mask.height {
            for mx in 0..<mask.width {
                let c = mask.coverage[my * mask.width + mx]
                if c > 0 { blend(x + mx, y + my, color, coverage: Float(c) / 255) }
            }
        }
    }

    /// Premultiplied BGRA, the format a layered window takes.
    func bgraPremultiplied() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            out[i] = Self.byte(pixels[i + 2])
            out[i + 1] = Self.byte(pixels[i + 1])
            out[i + 2] = Self.byte(pixels[i])
            out[i + 3] = Self.byte(pixels[i + 3])
        }
        return out
    }

    /// Straight-alpha BGRA, the format an icon takes.
    func bgraStraight() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[i + 3]
            guard a > 0 else { continue }
            out[i] = Self.byte(pixels[i + 2] / a)
            out[i + 1] = Self.byte(pixels[i + 1] / a)
            out[i + 2] = Self.byte(pixels[i] / a)
            out[i + 3] = Self.byte(a)
        }
        return out
    }

    private static func byte(_ v: Float) -> UInt8 { UInt8(min(max(v, 0), 1) * 255 + 0.5) }
}

enum Shape {
    static func roundedRect(_ px: Float, _ py: Float,
                            x: Float, y: Float, w: Float, h: Float, radius: Float) -> Float {
        let r = min(radius, min(w, h) / 2)
        let qx = abs(px - (x + w / 2)) - (w / 2 - r)
        let qy = abs(py - (y + h / 2)) - (h / 2 - r)
        let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
        return outside + min(max(qx, qy), 0) - r
    }

    static func ring(_ px: Float, _ py: Float, cx: Float, cy: Float, radius: Float, width: Float) -> Float {
        abs(hypot(px - cx, py - cy) - radius) - width / 2
    }

    /// A round-capped arc, clockwise from 12 o'clock through `fraction` of a turn.
    static func arc(_ px: Float, _ py: Float, cx: Float, cy: Float, radius: Float, width: Float,
                    fraction: Float) -> Float {
        let sweep = 2 * Float.pi * min(max(fraction, 0), 1)
        var angle = atan2(px - cx, cy - py)
        if angle < 0 { angle += 2 * .pi }
        var d = Float.greatestFiniteMagnitude
        if angle <= sweep { d = abs(hypot(px - cx, py - cy) - radius) - width / 2 }
        let start = hypot(px - cx, py - (cy - radius)) - width / 2
        let end = hypot(px - (cx + radius * sin(sweep)), py - (cy - radius * cos(sweep))) - width / 2
        return min(d, start, end)
    }
}

struct HUDTheme {
    var dark: Bool
    var translucent: Bool

    var fill: RGBA {
        dark ? RGBA(0.165, 0.165, 0.165, translucent ? 0.94 : 1)
             : RGBA(0.976, 0.976, 0.976, translucent ? 0.95 : 1)
    }
    var stroke: RGBA { dark ? RGBA(gray: 1, 0.10) : RGBA(gray: 0, 0.09) }
    var shadow: RGBA { RGBA(gray: 0, dark ? 0.42 : 0.20) }
    var title: RGBA { dark ? RGBA(gray: 1, 0.95) : RGBA(gray: 0, 0.89) }
    var secondary: RGBA { dark ? RGBA(gray: 1, 0.64) : RGBA(gray: 0, 0.60) }
    var track: RGBA { dark ? RGBA(gray: 1, 0.22) : RGBA(gray: 0, 0.13) }
    /// macOS systemGreen and systemRed, as in the Mac HUD's ring.
    var good: RGBA { dark ? RGBA(0.188, 0.820, 0.345) : RGBA(0.204, 0.780, 0.349) }
    var low: RGBA { dark ? RGBA(1, 0.271, 0.227) : RGBA(1, 0.231, 0.188) }
}

struct HUDContent: Equatable {
    var kind: HUDKind
    var name: String
    var battery: Int?
    var detail: String?
    var lowThreshold: Int
}

/// Pixel geometry with the Mac HUD's proportions, but text one step larger for the 14 px Windows UI.
struct WinHUDMetrics {
    var scale: Float

    var height: Float { 48 * scale }
    var glyphWidth: Float { 72 * scale }
    var titleSize: Int { Int((14 * scale).rounded()) }
    var statusSize: Int { Int((12 * scale).rounded()) }
    var ringDiameter: Float { 34 * scale }
    var ringLineWidth: Float { 4 * scale }
    var ringFontSize: Int { Int((11 * scale).rounded()) }
    var padLeading: Float { 14 * scale }
    var padTrailing: Float { 7 * scale }
    var gap: Float { 12 * scale }
    var minWidth: Float { 220 * scale }
    var maxWidth: Float { 380 * scale }
    var margin: Float { 14 * scale }
}

/// `capsule` is the capsule's rect inside the canvas, so placement can ignore the shadow.
struct HUDImage {
    var canvas: Canvas
    var capsule: (x: Int, y: Int, width: Int, height: Int)
}

enum HUDArt {
    /// US M0110 rows as key widths in hundredths of a unit, 1500 wide. A negative
    /// width is a gap. Same widths as M0110Layout.ansi.
    static let rows: [[Int32]] = [
        [100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 200],
        [150, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 150],
        [175, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 225],
        [225, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 275],
        [-100, 98, 149, 818, 140, 95],
    ]

    static let keys: [(x: Int32, y: Int32, width: Int32)] = rows.enumerated().flatMap { row, widths in
        var x: Int32 = 0
        return widths.compactMap { width -> (Int32, Int32, Int32)? in
            defer { x += abs(width) }
            return width > 0 ? (x, Int32(row) * 100, width) : nil
        }
    }

    /// The board seen from above, like the Mac's board art. `dim` grays it out for a dead battery.
    static func board(on canvas: inout Canvas, x: Float, y: Float, width: Float, dim: Bool) {
        let unitsWide: Float = 1500
        let unitsHigh: Float = 500
        let bezel: Float = 40
        let unit = width / (unitsWide + bezel * 2)
        let height = (unitsHigh + bezel * 2) * unit

        let fade: Float = dim ? 0.45 : 1
        let caseColor = RGBA(0.945, 0.922, 0.867, fade)
        let edge = RGBA(0.58, 0.54, 0.46, 0.65 * fade)
        let cap = RGBA(0.745, 0.706, 0.639, fade)
        let capEdge = RGBA(0.47, 0.43, 0.37, 0.55 * fade)

        canvas.fill(edge, in: (x - 1, y - 1, x + width + 1, y + height + 1)) {
            Shape.roundedRect($0, $1, x: x - 0.5, y: y - 0.5, w: width + 1, h: height + 1, radius: 3.5 * unit * 10)
        }
        canvas.fill(caseColor, in: (x, y, x + width, y + height)) {
            Shape.roundedRect($0, $1, x: x, y: y, w: width, h: height, radius: 3 * unit * 10)
        }

        let inset = 8 * unit
        let radius = max(14 * unit, 0.6)
        for key in keys {
            let kx = x + (bezel + Float(key.x)) * unit + inset
            let ky = y + (bezel + Float(key.y)) * unit + inset
            let kw = Float(key.width) * unit - inset * 2
            let kh = 100 * unit - inset * 2
            guard kw > 0, kh > 0 else { continue }
            canvas.fill(capEdge, in: (kx - 1, ky - 1, kx + kw + 1, ky + kh + 1)) {
                Shape.roundedRect($0, $1, x: kx - 0.35, y: ky - 0.35, w: kw + 0.7, h: kh + 0.7, radius: radius)
            }
            canvas.fill(cap, in: (kx, ky, kx + kw, ky + kh)) {
                Shape.roundedRect($0, $1, x: kx, y: ky, w: kw, h: kh, radius: radius)
            }
        }
    }

    static func boardHeight(width: Float) -> Float {
        let bezel: Float = 40
        return width * (500 + bezel * 2) / (1500 + bezel * 2)
    }

    static func ring(on canvas: inout Canvas, cx: Float, cy: Float, metrics m: WinHUDMetrics,
                     level: Int, isLow: Bool, theme: HUDTheme, text: TextRasterizer) {
        let lw = m.ringLineWidth
        let radius = m.ringDiameter / 2 - lw / 2 - 0.5
        let box = (cx - radius - lw, cy - radius - lw, cx + radius + lw, cy + radius + lw)
        canvas.fill(theme.track, in: box) {
            Shape.ring($0, $1, cx: cx, cy: cy, radius: radius, width: lw)
        }
        if level > 0 {
            let fraction = Float(min(level, 100)) / 100
            canvas.fill(isLow ? theme.low : theme.good, in: box) {
                Shape.arc($0, $1, cx: cx, cy: cy, radius: radius, width: lw, fraction: fraction)
            }
        }
        let label = text.render(String(level), size: m.ringFontSize, weight: 600,
                                maxWidth: Int(m.ringDiameter))
        canvas.draw(label, at: Int((cx - Float(label.width) / 2).rounded()),
                    Int((cy - Float(label.height) / 2).rounded()), theme.secondary)
    }

    static func render(_ content: HUDContent, metrics m: WinHUDMetrics, theme: HUDTheme,
                       text: TextRasterizer) -> HUDImage {
        let showRing = content.battery != nil && content.kind.showsRing
        let textRoom = Int(m.maxWidth - m.padLeading - m.glyphWidth - m.gap * 2 - m.padTrailing
                           - (showRing ? m.ringDiameter : 0))
        let title = text.render(content.name, size: m.titleSize, weight: 600, maxWidth: textRoom)
        let status = text.render(content.kind.status(detail: content.detail), size: m.statusSize,
                                 weight: 400, maxWidth: textRoom)
        let textWidth = Float(max(title.width, status.width))

        let natural = m.padLeading + m.glyphWidth + m.gap + textWidth + m.gap
            + (showRing ? m.ringDiameter : 0) + m.padTrailing
        let width = min(max(natural, m.minWidth), m.maxWidth).rounded()
        let height = m.height.rounded()
        let margin = m.margin.rounded()

        var canvas = Canvas(width: Int(width + margin * 2), height: Int(height + margin * 2))
        let x = margin, y = margin
        let radius = height / 2

        // Layered windows get no system shadow, so draw one.
        let blur = 9 * m.scale
        let drop = 3 * m.scale
        canvas.fill(theme.shadow, in: (0, 0, Float(canvas.width), Float(canvas.height))) { px, py in
            let d = Shape.roundedRect(px, py, x: x, y: y + drop, w: width, h: height, radius: radius)
            // Spread the edge over `blur` pixels and return the distance that gives that coverage.
            let t = min(max((d + blur * 0.4) / (blur * 1.4), 0), 1)
            return 0.5 - (1 - t * t * (3 - 2 * t))
        }
        canvas.fill(theme.stroke, in: (x - 1, y - 1, x + width + 1, y + height + 1)) {
            Shape.roundedRect($0, $1, x: x - 1, y: y - 1, w: width + 2, h: height + 2, radius: radius + 1)
        }
        // The fill replaces the pixels under it, so the shadow does not darken a translucent capsule.
        var fill = Canvas(width: canvas.width, height: canvas.height)
        fill.fill(theme.fill, in: (x, y, x + width, y + height)) {
            Shape.roundedRect($0, $1, x: x, y: y, w: width, h: height, radius: radius)
        }
        canvas.replace(with: fill, opacity: theme.fill.a)

        let glyphX = x + m.padLeading
        let boardH = boardHeight(width: m.glyphWidth)
        board(on: &canvas, x: glyphX, y: (y + (height - boardH) / 2).rounded(), width: m.glyphWidth,
              dim: content.kind == .died)

        let textLeft = glyphX + m.glyphWidth + m.gap
        let textRight = x + width - m.padTrailing - (showRing ? m.ringDiameter + m.gap : m.gap)
        let pairHeight = Float(title.height + status.height) - 2 * m.scale
        let top = y + (height - pairHeight) / 2
        let center = (textLeft + textRight) / 2
        canvas.draw(title, at: Int((center - Float(title.width) / 2).rounded()), Int(top.rounded()), theme.title)
        canvas.draw(status, at: Int((center - Float(status.width) / 2).rounded()),
                    Int((top + Float(title.height) - 2 * m.scale).rounded()), theme.secondary)

        if showRing, let level = content.battery {
            ring(on: &canvas, cx: x + width - m.padTrailing - m.ringDiameter / 2, cy: y + height / 2,
                 metrics: m, level: level, isLow: level <= content.lowThreshold, theme: theme, text: text)
        }
        return HUDImage(canvas: canvas, capsule: (Int(x), Int(y), Int(width), Int(height)))
    }

    /// A keyboard glyph from the icon font, or a drawn one if missing. Faded while the keyboard is away.
    static func trayIcon(size: Int, darkTaskbar: Bool, connected: Bool, text: TextRasterizer) -> Canvas {
        var canvas = Canvas(width: size, height: size)
        let ink = RGBA(gray: darkTaskbar ? 1 : 0, connected ? 1 : 0.45)
        // 0xE765 is KeyboardClassic.
        if let glyph = text.icon(0xE765, size: size) {
            canvas.draw(glyph, at: (size - glyph.width) / 2, (size - glyph.height) / 2, ink)
            return canvas
        }
        let s = Float(size)
        let w = s * 0.9, h = s * 0.56
        let x = (s - w) / 2, y = (s - h) / 2
        let line = max(1, s / 16)
        canvas.fill(ink, in: (x - 1, y - 1, x + w + 1, y + h + 1)) {
            abs(Shape.roundedRect($0, $1, x: x + line / 2, y: y + line / 2, w: w - line, h: h - line,
                                  radius: s / 10)) - line / 2
        }
        let key = s / 9
        for row in 0..<2 {
            for column in 0..<5 {
                let kx = x + w * 0.16 + Float(column) * w * 0.15
                let ky = y + h * 0.24 + Float(row) * h * 0.26
                canvas.fill(ink, in: (kx, ky, kx + key, ky + key)) {
                    Shape.roundedRect($0, $1, x: kx, y: ky, w: key, h: key, radius: key / 4)
                }
            }
        }
        let barY = y + h * 0.74, barX = x + w * 0.28
        canvas.fill(ink, in: (barX, barY - line, barX + w * 0.44, barY + line)) {
            Shape.roundedRect($0, $1, x: barX, y: barY - line / 2, w: w * 0.44, h: line, radius: line / 2)
        }
        return canvas
    }
}

extension HUDArt {
    /// Every state plus the tray icons, for `--snapshot` and tools/win-hud-preview.sh.
    static func sheet(scale: Float, text: TextRasterizer) -> Canvas {
        let samples: [HUDContent] = [
            HUDContent(kind: .arrived, name: "M0110", battery: 76, detail: nil, lowThreshold: 20),
            HUDContent(kind: .lowBattery, name: "M0110", battery: 15, detail: nil, lowThreshold: 20),
            HUDContent(kind: .disconnected, name: "M0110", battery: nil, detail: nil, lowThreshold: 20),
            HUDContent(kind: .died, name: "M0110", battery: 0, detail: nil, lowThreshold: 20),
            HUDContent(kind: .movedAway, name: "M0110", battery: 64, detail: "MacBook", lowThreshold: 20),
            HUDContent(kind: .movedBack, name: "M0110", battery: 64, detail: nil, lowThreshold: 20),
        ]
        let metrics = WinHUDMetrics(scale: scale)
        let themes = [false, true].map { dark in
            samples.map { render($0, metrics: metrics, theme: HUDTheme(dark: dark, translucent: true), text: text) }
        }
        let iconSize = Int(16 * scale)
        let icons = [false, true].flatMap { dark in
            [true, false].map { trayIcon(size: iconSize, darkTaskbar: dark, connected: $0, text: text) }
        }

        let images = themes.flatMap { $0 }
        let cellW = images.map(\.canvas.width).max() ?? 1
        let cellH = images.map(\.canvas.height).max() ?? 1
        let columns = 2
        let perTheme = (samples.count + columns - 1) / columns
        let strip = iconSize * 2
        var sheet = Canvas(width: cellW * columns, height: cellH * perTheme * 2 + strip)
        let light = RGBA(0.87, 0.875, 0.89), dark = RGBA(0.125, 0.14, 0.165)
        sheet.fill(light, in: (0, 0, Float(sheet.width), Float(cellH * perTheme))) { _, _ in -1 }
        sheet.fill(dark, in: (0, Float(cellH * perTheme), Float(sheet.width), Float(sheet.height))) { _, _ in -1 }

        for (t, row) in themes.enumerated() {
            for (i, image) in row.enumerated() {
                sheet.draw(image.canvas, at: (i % columns) * cellW, t * cellH * perTheme + (i / columns) * cellH)
            }
        }
        for (i, icon) in icons.enumerated() {
            sheet.draw(icon, at: iconSize / 2 + i * iconSize * 2, cellH * perTheme * 2 + (strip - iconSize) / 2)
        }
        return sheet
    }
}

extension Canvas {
    mutating func draw(_ other: Canvas, at x: Int, _ y: Int) {
        for oy in 0..<other.height {
            let ty = y + oy
            guard ty >= 0, ty < height else { continue }
            for ox in 0..<other.width {
                let tx = x + ox
                guard tx >= 0, tx < width else { continue }
                let s = (oy * other.width + ox) * 4
                let a = other.pixels[s + 3]
                guard a > 0 else { continue }
                let d = (ty * width + tx) * 4
                for c in 0..<4 { pixels[d + c] = other.pixels[s + c] + pixels[d + c] * (1 - a) }
            }
        }
    }

    /// A 32-bit BMP, which any viewer opens and which needs no encoder.
    func bmp() -> [UInt8] {
        var out: [UInt8] = []
        func le(_ value: UInt32, _ bytes: Int) {
            for i in 0..<bytes { out.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(i)))) }
        }
        let size = UInt32(width * height * 4)
        out += [0x42, 0x4D]                     // "BM"
        le(54 + size, 4); le(0, 4); le(54, 4)
        le(40, 4)                               // BITMAPINFOHEADER
        le(UInt32(width), 4)
        le(UInt32(bitPattern: Int32(-height)), 4)  // top-down
        le(1, 2); le(32, 2); le(0, 4); le(size, 4)
        le(2835, 4); le(2835, 4); le(0, 4); le(0, 4)
        out += bgraStraight()
        return out
    }
}

extension Canvas {
    mutating func replace(with other: Canvas, opacity: Float) {
        precondition(other.width == width && other.height == height)
        var mixed = pixels
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = other.pixels[i + 3]
            guard a > 0 else { continue }
            let keep = 1 - min(a / max(opacity, 0.001), 1)
            for c in 0..<4 { mixed[i + c] = other.pixels[i + c] + pixels[i + c] * keep }
        }
        self = Canvas(width: width, height: height, pixels: mixed)
    }

    private init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
