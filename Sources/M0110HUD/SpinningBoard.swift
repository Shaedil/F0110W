import AppKit
import CoreImage
import SceneKit
import SwiftUI

/// What the board does while a HUD is up. Every motion starts and ends at the rest pose
/// (top face toward the viewer) and never shows the underside.
enum BoardMotion: String, CaseIterable {
    /// Tip the top face toward the viewer a little, then ease back.
    case rock
    /// A quicker, deeper tip, then ease back.
    case wake
    case settle
    case still
    /// Form out of dust at rest, then rock.
    case assemble
    /// Ease back to rest while crumbling to dust, and stay gone.
    case dust
}

enum BoardTreatment: String, CaseIterable {
    case normal
    case dim
    /// Faded and desaturated.
    case grey
}

/// The 3D M0110 as the HUD glyph. It only rocks a little, since a full turn spends half its
/// time showing the edge and underside.
final class SpinningBoardView: NSView {
    /// Positive X tips the top toward the camera (35 degrees up), so this only shows more of the
    /// keys. Showing the underside would take 35 degrees the other way.
    private static let rockAngle: CGFloat = 22 * .pi / 180

    /// The board shows whole for at least `dustBeat`, then crumbles so the dust ends with the HUD
    /// fade. A longer hold only lengthens the beat. `dustEnds` is the shortest hold that fits.
    static let dustBeat: TimeInterval = 0.6
    static let dustDuration: TimeInterval = 2.4
    static var dustEnds: TimeInterval { dustBeat + dustDuration }

    static func dustBeat(hold: TimeInterval?) -> TimeInterval {
        guard let hold else { return dustBeat }
        return max(dustBeat, hold - dustDuration)
    }

    /// Texture width. Plenty for a glyph-sized view and cheap to redraw on a theme change.
    static let texturePixels: CGFloat = 1024

    private let sceneView = SCNView()
    private let board = BoardScene()
    private lazy var dissolve = BoardDissolve(board: board.boardNode)
    private var renderedScheme: ColorScheme?

    /// Below 50% battery the board fades with the level, down to 35% opacity at empty. The
    /// treatment and battery fades do not stack; the fainter one wins.
    func setTreatment(_ treatment: BoardTreatment, battery: Int?) {
        let treated: CGFloat = treatment == .normal ? 1 : 0.55
        alphaValue = min(treated, Self.batteryAlpha(battery))
        board.boardNode.filters = treatment == .grey
            ? [CIFilter(name: "CIColorControls",
                        parameters: [kCIInputSaturationKey: 0])].compactMap { $0 }
            : nil
    }

    static func batteryAlpha(_ battery: Int?) -> CGFloat {
        guard let battery, battery < 50 else { return 1 }
        return 0.35 + 0.65 * CGFloat(max(battery, 0)) / 50
    }

    private static let spinKey = "spin"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        wantsLayer = true

        sceneView.scene = board.scene
        _ = dissolve
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        // The HUD is a non-activating panel that ignores the mouse, so the scene must not take events.
        sceneView.allowsCameraControl = false
        sceneView.autoresizingMask = [.width, .height]
        sceneView.frame = bounds
        addSubview(sceneView)

        play(.still)
    }

    private static let easeInOut: SCNActionTimingFunction = { t in t * t * (3 - 2 * t) }
    /// Fast start, long settle, for motion that reacts to an event.
    private static let easeOut: SCNActionTimingFunction = { t in 1 - pow(1 - t, 3) }

    private static func tilt(to angle: CGFloat, duration: TimeInterval,
                             timing: @escaping SCNActionTimingFunction) -> SCNAction {
        let a = SCNAction.rotateTo(x: angle, y: 0, z: 0, duration: duration, usesShortestUnitArc: true)
        a.timingFunction = timing
        return a
    }

    private static var rock: SCNAction {
        .sequence([tilt(to: rockAngle, duration: 0.9, timing: easeInOut),
                   tilt(to: 0, duration: 1.2, timing: easeInOut)])
    }

    /// Back to rest, taking longer the further it has to go.
    private static func settle(from angle: CGFloat) -> SCNAction? {
        guard abs(angle) > 0.005 else { return nil }
        return tilt(to: 0, duration: max(0.4, Double(abs(angle) / rockAngle) * 0.9), timing: easeInOut)
    }

    /// Tilt about the long axis in -pi...pi, 0 at rest. The node only rotates about X, so its
    /// quaternion is (sin(a/2), 0, 0, cos(a/2)).
    private var currentAngle: CGFloat {
        let q = board.boardNode.presentation.orientation
        var angle = 2 * atan2(CGFloat(q.x), CGFloat(q.w))
        if angle > .pi { angle -= 2 * .pi }
        if angle < -.pi { angle += 2 * .pi }
        return angle
    }

    /// `reduced` is Reduce Motion: no movement, but the board still fades in and out. `hold` is
    /// how long the HUD stays up (nil uses the shortest timeline).
    func play(_ motion: BoardMotion, reduced: Bool = false, hold: TimeInterval? = nil) {
        let node = board.boardNode
        let angle = currentAngle
        let dustBeat = Self.dustBeat(hold: hold)
        node.removeAction(forKey: Self.spinKey)
        dissolve.reset()
        node.opacity = 1
        // Pin the model at the presentation pose so removing the old action does not snap it back.
        node.orientation = SCNQuaternion(sin(angle / 2), 0, 0, cos(angle / 2))

        if reduced {
            node.orientation = SCNQuaternion(0, 0, 0, 1)
            switch motion {
            case .assemble:
                node.opacity = 0
                node.runAction(.sequence([.wait(duration: 0.1), .fadeIn(duration: 0.3)]),
                               forKey: Self.spinKey)
            case .dust:
                node.runAction(.sequence([.wait(duration: dustBeat),
                                          .fadeOut(duration: Self.dustDuration)]),
                               forKey: Self.spinKey)
            case .rock, .wake, .settle, .still:
                break
            }
            return
        }

        switch motion {
        case .rock:
            // Settle if still tipped, then wait for the panel to arrive before rocking.
            let steps = [Self.settle(from: angle), .wait(duration: 0.3), Self.rock].compactMap { $0 }
            node.runAction(.sequence(steps), forKey: Self.spinKey)
        case .wake:
            let steps = [Self.settle(from: angle),
                         Self.tilt(to: Self.rockAngle * 1.6, duration: 0.45, timing: Self.easeOut),
                         Self.tilt(to: 0, duration: 1.3, timing: Self.easeInOut)].compactMap { $0 }
            node.runAction(.sequence(steps), forKey: Self.spinKey)
        case .settle:
            if let back = Self.settle(from: angle) {
                node.runAction(back, forKey: Self.spinKey)
            }
        case .still:
            node.orientation = SCNQuaternion(0, 0, 0, 1)
        case .assemble:
            // Form at rest as the panel slides in, then rock to show it is live.
            node.orientation = SCNQuaternion(0, 0, 0, 1)
            dissolve.set(progress: 1.02)
            node.runAction(.sequence([.wait(duration: 0.1),
                                      dissolve.form(duration: 1.2),
                                      Self.rock]), forKey: Self.spinKey)
        case .dust:
            // Ease back to rest while it crumbles, after showing the whole board for a beat.
            let crumble = SCNAction.sequence([.wait(duration: dustBeat),
                                              dissolve.crumble(duration: Self.dustDuration)])
            let parts = [Self.settle(from: angle), crumble].compactMap { $0 }
            node.runAction(.group(parts), forKey: Self.spinKey)
        }
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

    /// Starts or stops the render loop. The HUD code must call this, since the panel is reused
    /// and `orderOut` never removes the view from its window, so `viewDidMoveToWindow` would
    /// not stop rendering.
    func setSpinning(_ spinning: Bool) {
        sceneView.isPlaying = spinning
        if spinning { MainActor.assumeIsolated { refreshTexture() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { sceneView.isPlaying = false }
    }
}
