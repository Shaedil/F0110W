import CM0110Win
import Foundation

/// `--clipboard-probe`: the Windows clipboard and the image work, tried on
/// this PC's real clipboard. What the keyboard link needs from Windows, short
/// of the keyboard. Replaces whatever is on the clipboard.
enum ClipboardProbe {
    static func run() -> Int32 {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "ok  " : "FAIL") \(what)\(detail.isEmpty ? "" : ": \(detail)")")
            if !ok { failed += 1 }
        }
        let clipboard = WindowsClipboard()
        print("clipboard probe")

        // Text, through CRLF and back, with something outside ASCII.
        let text = Array("M0110 \u{2318} caf\u{E9}\nsecond line\n".utf8)
        let before = clipboard.sequence
        check("write text", clipboard.write(text: text))
        check("the sequence number moves", clipboard.sequence != before)
        check("read text back", clipboard.read() == .text(text), "\(clipboard.read())")

        // A password manager's marker.
        check("a concealed copy is seen as one", m0110_clip_probe_concealed("hunter2".wide) != 0 && clipboard.read() == .concealed,
              "\(clipboard.read())")

        // An image: the HUD's own drawing, as a BMP for the Imaging Component
        // to read, onto the clipboard as a bitmap and a PNG, and back.
        let sheet = Data(HUDArt.sheet(scale: 1, text: GDIText()).bmp())
        check("write an image", clipboard.write(image: sheet), "\(sheet.count) bytes of BMP")
        if case .png(let png) = clipboard.read() {
            check("read it back as PNG", png.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(png.count) bytes")
            let fitted = WindowsClipboard.shrink(ClipContent(kind: .png, data: png), toFit: 20_000)
            check("shrink it to fit the keyboard",
                  fitted.map { $0.kind == .jpeg && $0.data.count <= 20_000 && $0.data.starts(with: [0xFF, 0xD8]) } ?? false,
                  fitted.map { "\($0.data.count) bytes of JPEG" } ?? "nothing fitted")
        } else {
            check("read it back as PNG", false, "\(clipboard.read())")
        }

        // Only the bitmap, as most programs copy: read through CF_DIB.
        check("a bitmap alone is read as PNG", m0110_clip_probe_bitmap() != 0 && {
            if case .png(let png) = clipboard.read() { return png.starts(with: [0x89, 0x50, 0x4E, 0x47]) }
            return false
        }(), "\(clipboard.read())".prefix(40).description)

        print("  usb: the keyboard is \(m0110_usb_present(0x1D50, 0x615E, "M0110".wide) != 0 ? "" : "not ")plugged in")
        print(failed == 0 ? "all passed" : "\(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
