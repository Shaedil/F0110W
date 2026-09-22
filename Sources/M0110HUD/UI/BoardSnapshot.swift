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
