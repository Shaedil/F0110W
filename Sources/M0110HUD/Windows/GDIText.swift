import CM0110Win

struct GDIText: TextRasterizer {
    /// Not Segoe UI Variable, because GDI picks its weights by name and would fake the bold.
    static let faces = "Segoe UI;Tahoma".wide
    /// Both have KeyboardClassic. Fluent is on Windows 11, MDL2 on 10.
    static let iconFaces = "Segoe Fluent Icons;Segoe MDL2 Assets".wide

    func render(_ text: String, size: Int, weight: Int, maxWidth: Int) -> TextMask {
        draw(text.wide, faces: Self.faces, size: size, weight: weight, maxWidth: maxWidth)
            ?? TextMask(width: 0, height: 0, coverage: [])
    }

    func icon(_ codepoint: UInt32, size: Int) -> TextMask? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        return draw(String(Character(scalar)).wide, faces: Self.iconFaces, size: size, weight: 400,
                    maxWidth: size * 2)
    }

    private func draw(_ text: [UInt16], faces: [UInt16], size: Int, weight: Int, maxWidth: Int) -> TextMask? {
        var lineHeight: Int32 = 0
        let width = m0110_text(text, faces, Int32(size), Int32(weight), nil, Int32(maxWidth), 0, &lineHeight)
        guard width > 0, lineHeight > 0 else { return nil }
        var mask = [UInt8](repeating: 0, count: Int(width) * Int(lineHeight))
        _ = m0110_text(text, faces, Int32(size), Int32(weight), &mask, width, lineHeight, &lineHeight)
        return TextMask(width: Int(width), height: Int(lineHeight), coverage: mask)
    }
}
