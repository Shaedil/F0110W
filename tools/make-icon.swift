import AppKit

// The six-stripe Apple logo, drawn once at high resolution and scaled down so
// every icon size is sharp.

let outDir = CommandLine.arguments[1]

/// Top to bottom.
let stripes: [NSColor] = [
    NSColor(srgbRed: 0.38, green: 0.73, blue: 0.27, alpha: 1),
    NSColor(srgbRed: 0.99, green: 0.75, blue: 0.13, alpha: 1),
    NSColor(srgbRed: 0.96, green: 0.51, blue: 0.12, alpha: 1),
    NSColor(srgbRed: 0.87, green: 0.20, blue: 0.22, alpha: 1),
    NSColor(srgbRed: 0.60, green: 0.24, blue: 0.60, alpha: 1),
    NSColor(srgbRed: 0.00, green: 0.62, blue: 0.87, alpha: 1),
]

let authoringSide: CGFloat = 1024

func context(side: CGFloat) -> CGContext? {
    CGContext(data: nil, width: Int(side), height: Int(side),
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

func buildMark() -> CGImage? {
    guard let symbol = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) else {
        return nil
    }
    let config = NSImage.SymbolConfiguration(pointSize: authoringSide, weight: .regular)
    guard let shaped = symbol.withSymbolConfiguration(config),
          let glyph = shaped.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = context(side: authoringSide) else {
        return nil
    }
    ctx.interpolationQuality = .high

    let glyphWidth = authoringSide * CGFloat(glyph.width) / CGFloat(max(glyph.height, 1))
    let glyphRect = CGRect(x: (authoringSide - glyphWidth) / 2, y: 0,
                           width: glyphWidth, height: authoringSide)

    // Only paint stripes inside the glyph's rect. `destinationIn` does not touch
    // pixels outside it, so stripes there would show as bars down the sides.
    let band = authoringSide / CGFloat(stripes.count)
    for (i, colour) in stripes.enumerated() {
        ctx.setFillColor(colour.cgColor)
        // CGContext y grows upward, so the first stripe goes at the top. Stripes
        // overlap by half a point because touching fills leave a seam.
        let y = authoringSide - band * CGFloat(i + 1)
        ctx.fill(CGRect(x: glyphRect.minX, y: y - 0.5,
                        width: glyphRect.width, height: band + 1))
    }

    ctx.setBlendMode(.destinationIn)
    ctx.draw(glyph, in: glyphRect)
    return ctx.makeImage()
}

guard let mark = buildMark() else {
    FileHandle.standardError.write("could not build the mark\n".data(using: .utf8)!)
    exit(1)
}

func render(size side: CGFloat) -> NSImage? {
    guard let ctx = context(side: side) else { return nil }
    ctx.interpolationQuality = .high
    // Leave a margin like the one around macOS app icon artwork.
    let inset = (side * 0.13).rounded()
    ctx.draw(mark, in: CGRect(x: inset, y: inset,
                              width: side - inset * 2, height: side - inset * 2))
    guard let image = ctx.makeImage() else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: side, height: side))
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (px, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
                   (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
                   (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")] {
    guard let image = render(size: CGFloat(px)),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote \(outDir)")
