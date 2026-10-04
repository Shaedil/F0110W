import AppKit
import CoreImage
import SceneKit
import SwiftUI

/// What the board does while a HUD is up.
///
/// Every motion begins and ends at rest: the isometric pose the camera frames,
/// top face toward the viewer. None of them turns the board far enough to show
/// its underside.
enum BoardMotion: String, CaseIterable {
    /// Tip the top face toward the viewer a little, then ease back to rest.
    case rock
    /// A quicker, deeper tip on arrival, then ease back: the board waking up.
    case wake
    /// Ease back to rest from wherever it is.
    case settle
    /// At rest from the first frame, no motion at all.
    case still
    /// Form out of dust at rest, then rock: the snap run backwards.
    case assemble
    /// Ease back to rest while crumbling to dust, and stay gone.
    case dust
}

/// How the board is drawn while a HUD is up.
enum BoardTreatment: String, CaseIterable {
    case normal
    /// Faded, the way the flat glyph used to be when disconnected.
    case dim
    /// Faded and drained of colour.
    case grey
}

/// The 3D M0110 as the HUD's product glyph, rocking about its long axis.
///
/// It used to barrel-roll a full turn, forever. A full turn spends half its
/// time on the edge and the underside, which is nothing anyone needs to see in
/// a status HUD, so now it only rocks: a small tip toward the viewer and back.
final class SpinningBoardView: NSView {
    /// How far a rock tips the top face toward the viewer. Positive X turns
    /// the top toward the camera, which sits 35° up, so a tip this way only
    /// ever shows more of the keys; the underside would need a tip of 35° the
    /// other way.
    private static let rockAngle: CGFloat = 22 * .pi / 180

    /// The dust timeline, which the HUD's hold is cut to. The board is seen
    /// whole for a beat, then crumbles; the HUD starts fading out so that its
    /// fade and the last of the dust finish together.
    static let dustBeat: TimeInterval = 0.6
    static let dustDuration: TimeInterval = 2.4
    static var dustEnds: TimeInterval { dustBeat + dustDuration }

    /// Texture resolution. The art is around 2.6:1, so this is generous for a
    /// glyph-sized view and cheap enough to redraw when the theme changes.
    static let texturePixels: CGFloat = 1024

    private let sceneView = SCNView()
    private let board = BoardScene()
    private lazy var dissolve = BoardDissolve(board: board.boardNode)
    private var renderedScheme: ColorScheme?

    /// Apply a treatment, fading the board further as the battery runs down.
    ///
    /// Above half charge the battery does not touch it. Below, the board fades
    /// in step with the level, to 35% at empty, so a glance at its weight says
    /// roughly how much is left. A dimmed treatment and a low battery do not
    /// compound: the fainter of the two wins, so the board never vanishes
    /// before its animation has had its say.
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
        // The HUD is a non-activating panel that ignores the mouse; the scene
        // must not start claiming events inside it.
        sceneView.allowsCameraControl = false
        sceneView.autoresizingMask = [.width, .height]
        sceneView.frame = bounds
        addSubview(sceneView)

        play(.still)
    }

    /// Smooth both ends: motion that starts and ends on screen.
    private static let easeInOut: SCNActionTimingFunction = { t in t * t * (3 - 2 * t) }
    /// Fast start, long settle: motion that is a response to something.
    private static let easeOut: SCNActionTimingFunction = { t in 1 - pow(1 - t, 3) }

    private static func tilt(to angle: CGFloat, duration: TimeInterval,
                             timing: @escaping SCNActionTimingFunction) -> SCNAction {
        let a = SCNAction.rotateTo(x: angle, y: 0, z: 0, duration: duration, usesShortestUnitArc: true)
        a.timingFunction = timing
        return a
    }

    /// Tip toward the viewer and back to rest.
    private static var rock: SCNAction {
        .sequence([tilt(to: rockAngle, duration: 0.9, timing: easeInOut),
                   tilt(to: 0, duration: 1.2, timing: easeInOut)])
    }

    /// Back to rest, taking longer the further it has to go.
    private static func settle(from angle: CGFloat) -> SCNAction? {
        guard abs(angle) > 0.005 else { return nil }
        return tilt(to: 0, duration: max(0.4, Double(abs(angle) / rockAngle) * 0.9), timing: easeInOut)
    }

    /// The board's tilt about its long axis, in -π...π, 0 being at rest. The
    /// node only ever turns about X, so its orientation is (sin θ/2, 0, 0, cos θ/2).
    private var currentAngle: CGFloat {
        let q = board.boardNode.presentation.orientation
        var angle = 2 * atan2(CGFloat(q.x), CGFloat(q.w))
        if angle > .pi { angle -= 2 * .pi }
        if angle < -.pi { angle += 2 * .pi }
        return angle
    }

    /// Start a motion, from wherever the board currently is.
    ///
    /// `reduced` is Reduce Motion: nothing turns and nothing flies, but the
    /// meaning survives as opacity, so the board still arrives on connect and
    /// leaves on disconnect.
    func play(_ motion: BoardMotion, reduced: Bool = false) {
        let node = board.boardNode
        let angle = currentAngle
        node.removeAction(forKey: Self.spinKey)
        dissolve.reset()
        node.opacity = 1
        // Pin the model where the presentation was, so dropping the old
        // action does not snap it back to where that action started.
        node.orientation = SCNQuaternion(sin(angle / 2), 0, 0, cos(angle / 2))

        if reduced {
            node.orientation = SCNQuaternion(0, 0, 0, 1)
            switch motion {
            case .assemble:
                node.opacity = 0
                node.runAction(.sequence([.wait(duration: 0.1), .fadeIn(duration: 0.3)]),
                               forKey: Self.spinKey)
            case .dust:
                node.runAction(.sequence([.wait(duration: Self.dustBeat),
                                          .fadeOut(duration: Self.dustDuration)]),
                               forKey: Self.spinKey)
            case .rock, .wake, .settle, .still:
                break
            }
            return
        }

        switch motion {
        case .rock:
            // Settle first if a previous motion left it tipped, then a beat
            // so the rock starts once the panel has arrived, not during it.
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
            // Formed at rest, starting as the panel slides in so the two read
            // as one arrival, then a rock to show it is live.
            node.orientation = SCNQuaternion(0, 0, 0, 1)
            dissolve.set(progress: 1.02)
            node.runAction(.sequence([.wait(duration: 0.1),
                                      dissolve.form(duration: 1.2),
                                      Self.rock]), forKey: Self.spinKey)
        case .dust:
            // Ease back to rest while it crumbles; the board is seen whole
            // for a beat before it goes.
            let crumble = SCNAction.sequence([.wait(duration: Self.dustBeat),
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
