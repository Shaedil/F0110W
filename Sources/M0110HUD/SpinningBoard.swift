import AppKit
import SceneKit
import SwiftUI

/// The 3D M0110 turning slowly, as the HUD's product glyph.
///
/// The spin is deliberately slow. At a few seconds per turn the eye reads a
/// rotating object; faster and it reads as a flicker at the edge of the screen,
/// which is the opposite of what a status HUD wants.
final class SpinningBoardView: NSView {
    /// Seconds for one full turn.
    private static let turnDuration: TimeInterval = 7.5

    /// Texture resolution. The art is around 2.6:1, so this is generous for a
    /// glyph-sized view and cheap enough to redraw when the theme changes.
    static let texturePixels: CGFloat = 1024

    private let sceneView = SCNView()
    private let board = BoardScene()
    private var renderedScheme: ColorScheme?

    /// A disconnected board is dimmed, the way the flat glyph used to be.
    var isDimmed = false {
        didSet { alphaValue = isDimmed ? 0.55 : 1 }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        wantsLayer = true

        sceneView.scene = board.scene
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        // The HUD is a non-activating panel that ignores the mouse; the scene
        // must not start claiming events inside it.
        sceneView.allowsCameraControl = false
        sceneView.autoresizingMask = [.width, .height]
        sceneView.frame = bounds
        addSubview(sceneView)

        let turn = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: Self.turnDuration)
        turn.timingMode = .linear
        board.boardNode.runAction(.repeatForever(turn))
    }

    @MainActor
    private func refreshTexture() {
        let scheme: ColorScheme =
            effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        guard scheme != renderedScheme else { return }
        board.applyArt(colorScheme: scheme, pixelsWide: Self.texturePixels)
        renderedScheme = scheme
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        MainActor.assumeIsolated { refreshTexture() }
    }

    /// Start or stop the render loop.
    ///
    /// This has to be driven by whoever shows and hides the HUD. It cannot key
    /// off `viewDidMoveToWindow`: the panel is built once and reused, so hiding
    /// it with `orderOut` never takes the view out of its window, which left
    /// the scene rendering continuously from the first HUD onward.
    func setSpinning(_ spinning: Bool) {
        sceneView.isPlaying = spinning
        if spinning { MainActor.assumeIsolated { refreshTexture() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { sceneView.isPlaying = false }
    }
}
