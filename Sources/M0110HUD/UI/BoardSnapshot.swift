import AppKit
import SceneKit
import SwiftUI

/// Renders the spinning board offscreen as a strip of frames through one turn.
///
/// The HUD is a borderless panel that lives for seven seconds, so the usual way
/// to look at it is a screen capture with the timing guessed right. This draws
/// the same scene straight to a PNG instead, with no keyboard, no screen
/// recording permission, and every frame at a known angle.
@MainActor
enum BoardSnapshot {
    /// Frames across one full turn, evenly spaced.
    private static let frameCount = 6
    private static let frameSize = CGSize(width: 260, height: 180)

    static func render(to path: String, appearance: String?) -> Int32 {
        let scheme: ColorScheme = appearance == "light" ? .light : .dark
        let board = BoardScene()
        board.applyArt(colorScheme: scheme)

        // SCNRenderer draws a scene with no view and no window attached, which
        // is what this needs: SCNView.snapshot() has to be on screen to give
        // anything but an empty frame.
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = board.scene
        renderer.autoenablesDefaultLighting = false

        let strip = NSImage(size: CGSize(width: frameSize.width * CGFloat(frameCount),
                                         height: frameSize.height))
        strip.lockFocus()
        // Flat ground so the cream case is visible; the HUD's own background is
        // vibrancy, which cannot be reproduced offscreen anyway.
        (scheme == .dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.86, alpha: 1)).setFill()
        NSRect(origin: .zero, size: strip.size).fill()

        for i in 0..<frameCount {
            let angle = CGFloat(i) / CGFloat(frameCount) * 2 * .pi
            // X, matching the barrel roll `SpinningBoardView` runs: a strip
            // sampled about a different axis than the HUD turns on would be
            // checking a rotation nobody ever sees.
            board.boardNode.eulerAngles = SCNVector3(angle, 0, 0)
            let frame = renderer.snapshot(atTime: 0, with: frameSize,
                                          antialiasingMode: .multisampling4X)
            frame.draw(in: NSRect(x: CGFloat(i) * frameSize.width, y: 0,
                                  width: frameSize.width, height: frameSize.height))
        }
        strip.unlockFocus()

        guard let tiff = strip.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("board snapshot failed\n".data(using: .utf8)!)
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)  (\(frameCount) frames through one turn)")
            return 0
        } catch {
            FileHandle.standardError.write("board snapshot write failed: \(error)\n".data(using: .utf8)!)
            return 1
        }
    }
}

/// Renders the window's 3D stage at every focus as a grid, for the same
/// reason as `BoardSnapshot`: the camera only lands on each part after a pane
/// switch, which is awkward to screen-capture at the right moment.
@MainActor
enum BoardStageSnapshot {
    private static let focuses: [BoardFocus] = [.editor, .overview, .gestures,
                                                .battery, .radio]
    private static let frameSize = CGSize(width: 420, height: 460)
    private static let columns = 3

    static func render(to path: String) -> Int32 {
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.autoenablesDefaultLighting = false
        let rows = (focuses.count + columns - 1) / columns
        let sheet = NSImage(size: CGSize(width: frameSize.width * CGFloat(columns),
                                         height: frameSize.height * CGFloat(rows)))
        sheet.lockFocus()
        NSColor(srgbRed: 0.12, green: 0.115, blue: 0.11, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (i, focus) in focuses.enumerated() {
            // A fresh stage each time, so every frame shows a focus landed on
            // from rest rather than mid-flight from the last one.
            guard let stage = BoardStage() else {
                FileHandle.standardError.write("stage snapshot: M0110.usdz not found\n".data(using: .utf8)!)
                return 1
            }
            stage.paintBlank()
            if focus == .editor { paintSample(stage) }
            stage.setBattery(72, low: 20, rearm: 30)
            stage.setFocus(focus, animated: false)
            // Actions do not run in an offscreen render, so the gauge's fill is
            // set directly: a new reading repaints it without animating.
            stage.setBattery(73, low: 20, rearm: 30)
            renderer.scene = stage.scene
            renderer.pointOfView = stage.cameraNode
            // The editor is drawn in the Keyboard pane's wide box, so it is
            // checked at that shape: 990 by 420.
            let size = focus == .editor ? CGSize(width: frameSize.width, height: frameSize.width * 420 / 990)
                                        : frameSize
            let frame = renderer.snapshot(atTime: 0, with: size,
                                          antialiasingMode: .multisampling4X)
            let column = i % columns, row = rows - 1 - i / columns
            frame.draw(in: NSRect(x: CGFloat(column) * frameSize.width,
                                  y: CGFloat(row) * frameSize.height + (frameSize.height - size.height),
                                  width: size.width, height: size.height))
            focus.caption.draw(at: NSPoint(x: CGFloat(column) * frameSize.width + 12,
                                           y: CGFloat(row) * frameSize.height + 12),
                               withAttributes: [.foregroundColor: NSColor.white,
                                                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        }
        sheet.unlockFocus()

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)  (\(focuses.count) focuses)")
            return 0
        } catch {
            FileHandle.standardError.write("stage snapshot write failed: \(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    /// The sample keymap's legends on the editor frame, with one key selected.
    private static func paintSample(_ stage: BoardStage) {
        let controller = KeyboardController()
        controller.loadPreviewFixture()
        controller.selectedKey = 25
        for tag in stage.capTags {
            guard let size = stage.capFaces[tag] else { continue }
            let position = Int(tag.split(separator: "_").first ?? "") ?? M0110Layout.unmapped
            stage.paint(tag, face: CapFace(legend: controller.legend(forKeyAt: position),
                                           isSelected: controller.selectedKey == position,
                                           isEditable: controller.acceptsKeycode(at: position),
                                           isSpacebar: position == M0110Layout.spacebarPosition,
                                           size: size).image())
        }
    }
}
