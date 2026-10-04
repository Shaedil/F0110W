import AppKit
import SceneKit

/// The snap: the board crumbling into dust, or forming out of it.
///
/// Two parts that move together. A shader modifier on every material of the
/// board discards fragments behind a sweep that runs across the board's long
/// axis, ragged with per-cell noise so it eats the case in grains rather than
/// along a clean line, with a darker band at the front like an edge burning.
/// And a particle emitter, a thin slab riding that front, sheds dust that the
/// wind carries up and away.
///
/// The sweep runs in world X. The board only ever turns about X, so world X is
/// its own long axis at every angle of its rock.
final class BoardDissolve {
    private let materials: [SCNMaterial]
    private let minX: Float
    private let maxX: Float
    private let emitterNode = SCNNode()
    private let particles = SCNParticleSystem()

    /// Particles per second while the front is moving. Dust, not confetti:
    /// enough that the board visibly turns into it.
    private static let dustRate: CGFloat = 4000

    private static let shader = """
    #pragma arguments
    float dissolveProgress;
    float dissolveMaxX;
    float dissolveSpan;
    #pragma body
    float4 world = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float3 cell = floor(world.xyz * 70.0);
    float grain = fract(sin(dot(cell, float3(12.9898, 78.233, 37.719))) * 43758.5453);
    float along = clamp((dissolveMaxX - world.x) / dissolveSpan, 0.0, 1.0);
    float t = along * 0.8 + grain * 0.2;
    if (t < dissolveProgress) { discard_fragment(); }
    float ember = (1.0 - smoothstep(0.0, 0.06, t - dissolveProgress)) * step(0.001, dissolveProgress);
    _output.color.rgb = mix(_output.color.rgb, float3(0.32, 0.27, 0.23), ember * 0.85);
    """

    init(board: SCNNode) {
        var seen = Set<ObjectIdentifier>()
        var found: [SCNMaterial] = []
        board.enumerateHierarchy { node, _ in
            for m in node.geometry?.materials ?? [] where seen.insert(ObjectIdentifier(m)).inserted {
                found.append(m)
            }
        }
        materials = found

        let (lo, hi) = board.boundingBox
        minX = Float(lo.x)
        maxX = Float(hi.x)
        for m in materials {
            m.shaderModifiers = [.fragment: Self.shader]
            m.setValue(NSNumber(value: maxX), forKey: "dissolveMaxX")
            m.setValue(NSNumber(value: maxX - minX), forKey: "dissolveSpan")
        }

        // A slab the board's own thickness and depth, a sliver wide, carried by
        // the board so it turns with it.
        let p = particles
        p.emitterShape = SCNBox(width: 0.04, height: hi.y - lo.y, length: hi.z - lo.z, chamferRadius: 0)
        p.birthLocation = .volume
        p.birthDirection = .random
        p.birthRate = 0
        p.loops = true
        p.isLocal = false
        p.particleLifeSpan = 1.4
        p.particleLifeSpanVariation = 0.6
        p.particleSize = 0.018
        p.particleSizeVariation = 0.01
        p.particleVelocity = 0.12
        p.particleVelocityVariation = 0.1
        p.particleColor = NSColor(srgbRed: 0.62, green: 0.58, blue: 0.52, alpha: 1)
        p.particleColorVariation = SCNVector4(0, 0, 0.25, 0)
        p.isLightingEnabled = false
        p.blendMode = .alpha
        let fade = CAKeyframeAnimation()
        fade.values = [1, 0.9, 0]
        fade.keyTimes = [0, 0.5, 1]
        p.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        emitterNode.addParticleSystem(p)
        board.addChildNode(emitterNode)

        reset()
    }

    /// Whole board, no dust in the air from this point on.
    func reset() {
        set(progress: 0)
        particles.birthRate = 0
    }

    /// 0 is the whole board, 1 is none of it.
    func set(progress: Float) {
        for m in materials { m.setValue(NSNumber(value: progress), forKey: "dissolveProgress") }
        emitterNode.position.x = CGFloat(maxX - min(max(progress, 0), 1) * (maxX - minX))
    }

    /// Crumble away: the front runs from the right end to the left and the
    /// dust goes up and off to the right.
    func crumble(duration: TimeInterval) -> SCNAction {
        // Ease-in-out, so it erodes steadily and the last of it goes at the
        // end of the run; an ease-out took most of the board in the first
        // half and left a near-empty one standing for the second.
        sweep(from: 0, to: 1.02, duration: duration,
              wind: SCNVector3(0.9, 0.35, 0), lifeSpan: 1.0,
              easing: { x in x * x * (3 - 2 * x) })
    }

    /// Form: the same front run backwards. Real dust cannot be run backwards,
    /// so this one only glitters at the edge, short-lived and barely drifting.
    func form(duration: TimeInterval) -> SCNAction {
        sweep(from: 1.02, to: 0, duration: duration,
              wind: SCNVector3(-0.15, 0.1, 0), lifeSpan: 0.45,
              easing: { x in 1 - (1 - x) * (1 - x) })
    }

    private func sweep(from: Float, to: Float, duration: TimeInterval,
                       wind: SCNVector3, lifeSpan: CGFloat,
                       easing: @escaping (Float) -> Float) -> SCNAction {
        let start = SCNAction.run { [weak self] _ in
            guard let self else { return }
            particles.acceleration = wind
            particles.particleLifeSpan = lifeSpan
            particles.birthRate = Self.dustRate
        }
        let run = SCNAction.customAction(duration: duration) { [weak self] _, elapsed in
            let x = min(Float(elapsed / CGFloat(duration)), 1)
            self?.set(progress: from + (to - from) * easing(x))
        }
        let stop = SCNAction.run { [weak self] _ in
            self?.set(progress: to)
            self?.particles.birthRate = 0
        }
        return .sequence([start, run, stop])
    }
}
