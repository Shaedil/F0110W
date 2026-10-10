import AppKit
import SwiftUI

/// Renders the interface offscreen to a PNG, for review without the keyboard.
@MainActor
enum Snapshot {
    static func render(to path: String, pane: String?, appearance: String? = nil,
                       time: String? = nil,
                       width: CGFloat = 1340, height: CGFloat = 820) -> Int32 {
        // Force the appearance so either theme can be rendered.
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        let controller = KeyboardController()
        controller.loadPreviewFixture()

        // SwiftUI reads dynamic colors from `colorScheme` and ignores
        // NSApp.appearance, so set the scheme on the view too.
        let scheme: ColorScheme? = switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }

        let root = RootView(controller: controller,
                            initialPane: Pane(rawValue: pane ?? "Keyboard") ?? .keys)
            .environment(\.classicSnapshot, true)
            .environment(\.skyTime, time.flatMap(today))
            .environment(\.colorScheme, scheme ?? (NSApp.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light))
            // Top-leading, because snapshots drop the scroll view and a
            // centered frame would clip the top of a tall pane.
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

    /// "HH:MM" as that time today.
    private static func today(_ hhmm: String) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }
}
