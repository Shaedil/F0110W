import AppKit

// The classic six-stripe Apple mark, drawn clean.
//
// It used to be deliberately pixelated: the glyph was rasterised onto a 26px
// grid, its alpha hard-thresholded, and then upscaled with nearest-neighbour so
// the blocks stayed square. That reads as a Mac OS 9 menu icon at 512px, which
// is not what an app icon should look like on a Retina display.
//
// Now the mark is built once at high resolution and scaled down with smooth
// interpolation, so every size in the iconset is crisp.

let outDir = CommandLine.arguments[1]

/// Top to bottom, as Apple ordered them from 1977.
let stripes: [NSColor] = [
    NSColor(srgbRed: 0.38, green: 0.73, blue: 0.27, alpha: 1),
    NSColor(srgbRed: 0.99, green: 0.75, blue: 0.13, alpha: 1),
    NSColor(srgbRed: 0.96, green: 0.51, blue: 0.12, alpha: 1),
    NSColor(srgbRed: 0.87, green: 0.20, blue: 0.22, alpha: 1),
    NSColor(srgbRed: 0.60, green: 0.24, blue: 0.60, alpha: 1),
    NSColor(srgbRed: 0.00, green: 0.62, blue: 0.87, alpha: 1),
]

/// Resolution the mark is authored at. Every icon size is scaled from this one
/// image rather than re-rasterising the glyph small, which is what keeps the
/// stripe edges consistent between sizes.
let authoringSide: CGFloat = 1024

func context(side: CGFloat) -> CGContext? {
    CGContext(data: nil, width: Int(side), height: Int(side),
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// The striped mark, at authoring resolution.
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

    // The glyph is taller than it is wide, so centre it and keep its aspect.
    let glyphWidth = authoringSide * CGFloat(glyph.width) / CGFloat(max(glyph.height, 1))
    let glyphRect = CGRect(x: (authoringSide - glyphWidth) / 2, y: 0,
                           width: glyphWidth, height: authoringSide)

    // Bands are painted only across the glyph's own rect. `destinationIn` keeps
    // just the pixels the mask covers, so stripes laid outside that rect would
    // survive as bars down the sides.
    let band = authoringSide / CGFloat(stripes.count)
    for (i, colour) in stripes.enumerated() {
        ctx.setFillColor(colour.cgColor)
        // CGContext y grows upward, so the first stripe belongs at the top.
        // Overlap by half a point each way; abutting fills leave a seam.
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
    // The mark sits inside the icon's own margin, the way a macOS app icon's
    // artwork sits inside its tile.
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
