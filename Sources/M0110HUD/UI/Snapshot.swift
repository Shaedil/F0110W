import AppKit
import SwiftUI

/// Renders the interface offscreen to a PNG. Lets the design be reviewed without
/// the keyboard attached, unlocked, or the screen free for a capture.
@MainActor
enum Snapshot {
    static func render(to path: String, pane: String?, appearance: String? = nil,
                       width: CGFloat = 1340, height: CGFloat = 820) -> Int32 {
        // Force the app appearance so both themes can be rendered on demand;
        // otherwise the snapshot follows the system setting.
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        let controller = KeyboardController()
        controller.loadPreviewFixture()

        // SwiftUI resolves dynamic colours from `colorScheme`, not from
        // NSApp.appearance, so the scheme has to be set on the view itself.
        let scheme: ColorScheme? = switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }

        let root = RootView(controller: controller,
                            initialPane: Pane(rawValue: pane ?? "Keys") ?? .keys)
            .environment(\.classicSnapshot, true)
            .environment(\.colorScheme, scheme ?? (NSApp.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light))
            // Top-leading rather than centred. Snapshots drop the scroll view,
            // so a pane taller than the window renders taller than the frame,
            // and a centred frame then clips the top, which is where the window
            // controls and the sidebar's header live.
            .frame(width: width, height: height, alignment: .topLeading)

        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("snapshot failed\n".data(using: .utf8)!)
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)  (\(Int(width))x\(Int(height)) @2x)")
            return 0
        } catch {
            FileHandle.standardError.write("snapshot write failed: \(error)\n".data(using: .utf8)!)
            return 1
        }
    }
}
