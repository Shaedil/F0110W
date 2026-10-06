import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Images on the way to and from the pasteboard.
enum ClipImage {
    static let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    /// What a copy made here holds: the image as the pasteboard had it, which
    /// may still need converting before it can travel.
    struct Source {
        let data: Data
        let type: NSPasteboard.PasteboardType

        /// The kind it travels as. TIFF, which is what AppKit itself puts on
        /// the pasteboard, is not one of them and goes as PNG.
        var kind: ClipContent.Kind { type == ClipImage.jpegType ? .jpeg : .png }

        /// The bytes that travel. Converting is left until they are asked
        /// for, since most copies are never pasted on another computer.
        func content() -> ClipContent? {
            if type == .tiff {
                guard let png = ClipImage.convert(data, to: .png) else { return nil }
                return ClipContent(kind: .png, data: png)
            }
            return ClipContent(kind: kind, data: data)
        }
    }

    /// The forms of image that are read, in order of preference.
    private static let types: [NSPasteboard.PasteboardType] = [.png, jpegType, .tiff]

    /// Whether `pasteboard` holds an image, without reading it.
    static func isOn(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: types) != nil
    }

    /// The image on `pasteboard`, if it holds one.
    static func read(_ pasteboard: NSPasteboard) -> Source? {
        for type in types {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return Source(data: data, type: type)
            }
        }
        return nil
    }

    /// Re-encodes image data. Used for the forms of a delivered image that
    /// are only made if a program asks the pasteboard for them.
    static func convert(_ data: Data, to type: NSBitmapImageRep.FileType) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: type, properties: [:])
    }

    /// Longest side in pixels, and JPEG quality, tried in turn until the
    /// result fits. A screenshot of text stays legible further down this list
    /// than a photograph stays pleasant.
    private static let ladder: [(side: Int, quality: Double)] = [
        (2048, 0.6), (1600, 0.6), (1280, 0.5), (1024, 0.5), (800, 0.45), (640, 0.4), (480, 0.4),
        (320, 0.35), (200, 0.3),
    ]

    /// `content` made to fit in `budget` bytes: as it is if it already does,
    /// otherwise scaled down and re-encoded as JPEG. Nil if nothing fits.
    static func shrink(_ content: ClipContent, toFit budget: Int) -> ClipContent? {
        if content.data.count <= budget { return content }
        guard let source = CGImageSourceCreateWithData(content.data as CFData, nil) else {
            return nil
        }

        for step in ladder {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: step.side,
            ]
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary),
                let image = flattened(scaled) else { continue }

            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: step.quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), out.length <= budget {
                return ClipContent(kind: .jpeg, data: out as Data)
            }
        }
        return nil
    }

    /// JPEG has no transparency, and what shows through otherwise is black.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}
