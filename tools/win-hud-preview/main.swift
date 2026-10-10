// Draws the Windows HUD on a Mac: every state, light and dark, one PNG.
// Built and run by tools/win-hud-preview.sh with Sources/M0110HUD/Windows/
// HUDRaster.swift, so the look can be worked on without a Windows machine.
// Text comes from Core Text here rather than GDI, so it is close, not exact.
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct CoreTextRasterizer: TextRasterizer {
    func render(_ text: String, size: Int, weight: Int, maxWidth: Int) -> TextMask {
        let font = NSFont.systemFont(ofSize: CGFloat(size), weight: weight >= 600 ? .semibold : .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = max(1, Int(CTLineGetTypographicBounds(line, &ascent, &descent, &leading).rounded(.up)))
        // GDI's line height, roughly: Segoe UI's is 1.33 em.
        let height = Int((CGFloat(size) * 1.33).rounded())
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.textPosition = CGPoint(x: 0, y: (CGFloat(height) - ascent - descent) / 2 + descent)
        CTLineDraw(line, context)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return TextMask(width: width, height: height,
                        coverage: Array(UnsafeBufferPointer(start: data, count: width * height)))
    }

    func icon(_ codepoint: UInt32, size: Int) -> TextMask? { nil }
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "win-hud-preview.png"
let scale = CommandLine.arguments.count > 2 ? Float(CommandLine.arguments[2]) ?? 1.5 : 1.5
let sheet = HUDArt.sheet(scale: scale, text: CoreTextRasterizer())

let provider = CGDataProvider(data: Data(sheet.bgraStraight()) as CFData)!
let image = CGImage(width: sheet.width, height: sheet.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: sheet.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                             | CGImageAlphaInfo.first.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print(path)
