import AppKit
import SceneKit
import SwiftUI

/// What the stage's camera is looking at. Each pane, and each Settings tab,
/// picks the part of the keyboard it is about.
enum BoardFocus: Equatable {
    /// The Keyboard pane's editor: the whole board, near top-down.
    case editor
    case overview
    /// The Soli radar board under the right of the keyboard, which reads
    /// hand gestures over the keys.
    case gestures
    case popup
    case battery
    /// The nice!nano, whose radio carries the clipboard and the profiles.
    case radio

    init(pane: Pane, settingsTab: SettingsTab) {
        switch pane {
        // The Keyboard pane's own board is framed this way, so the stage
        // waiting behind it is too, and leaving that pane flies on from the
        // view the eye was already on.
        case .keys: self = .editor
        case .bluetooth: self = .radio
        case .battery: self = .battery
        case .gestures: self = .gestures
        case .settings:
            switch settingsTab {
            case .popup: self = .popup
            case .clipboard: self = .radio
            }
        }
    }

    var caption: String {
        switch self {
        case .editor, .overview, .popup: return "Apple M0110"
        case .gestures: return "Soli Radar Chip"
        case .battery: return "10,000 mAh LiPo cell"
        case .radio: return "Bluetooth Chip"
        }
    }
}

/// The 3D M0110 the side panes zoom around.
///
/// The case is StephenLulz's measured reproduction (Thingiverse 4061711,
/// CC BY); the keycaps, switches and converter boards were modelled to go in
/// it. Everything comes from `Resources/M0110.usdz`, exported from
/// `assets/M0110.blend`, with every key, switch and board as a named node so
/// this class can find and move them.
///
/// One instance lives for the whole window, so moving between panes flies the
/// camera from one part to the next rather than cutting.
final class BoardStage {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    /// The board, re-centred so the camera's targets can be given from its
    /// middle.
    private let board = SCNNode()
    /// The camera hangs off two nodes: `rig` sits on the target and turns,
    /// `sway` adds the idle drift on top, and the camera itself only ever
    /// moves along its own z, which is the distance.
    private let rig = SCNNode()
    private let sway = SCNNode()

    private var caseMaterials: [SCNMaterial] = []
    /// The key a pane is about gets materials of its own, so it can turn to
    /// glass while the rest stay solid.
    private var featuredMaterials: [String: [SCNMaterial]] = [:]
    private static let featuredKeys = ["71_0"]
    /// Everything that sits on the case top: caps, switches, plate, PCB.
    private var upper: SCNNode?
    private var upperRest = SCNVector3Zero
    private var look = Look(caseXray: 0, featured: [:])

    /// A key and what moves with it when it is pressed.
    private struct Key {
        let cap: SCNNode
        let stem: SCNNode?
        /// Straight down the switch, in the cap's parent's space.
        let down: SCNVector3
        let rest: SCNVector3
        let stemRest: SCNVector3?
    }
    private var keys: [String: Key] = [:]
    private var battery: SCNNode?
    private static let batteryScale: Float = 1.6
    /// Half the modelled cell's 6 mm thickness, before scaling.
    private static let batteryHalfHeight: Float = 0.003
    /// The charge gauge printed on the cell: ten segments, lit to the level.
    private var gaugeSegments: [SCNNode] = []
    private var batteryLevel: Int?
    private var gaugeColour = NSColor(srgbRed: 0.35, green: 0.86, blue: 0.42, alpha: 1)
    /// At or under the low-battery alert, when the last segment blinks.
    private var gaugeLow = false
    private var nano: SCNNode?
    /// The Soli radar board. Not in the model: built here, where the board
    /// will go, on the case floor under the right-hand keys.
    private var soli: SCNNode?
    private var plateMaterial: SCNMaterial?
    /// Each cap's own material, which its legend is painted into.
    private var capMaterials: [String: SCNMaterial] = [:]
    /// Each cap's top face, in metres: the area its painted face covers.
    private(set) var capFaces: [String: CGSize] = [:]
    /// Whatever the current focus added to the scene, removed on the next one.
    private var effects: [SCNNode] = []
    private(set) var focus: BoardFocus?
    /// The last focus a visible stage showed, so the Keyboard pane's board
    /// can start there and fly back to the whole board instead of cutting.
    @MainActor static var lastShown: BoardFocus?

    /// Switch travel, a little over the real 3.5 mm so it reads at a distance.
    private static let travel: CGFloat = 0.004

    init?() {
        guard let url = Self.resourceURL("M0110"),
              let model = try? SCNScene(url: url),
              let root = model.rootNode.childNode(withName: "M0110", recursively: true)
        else { return nil }

        // Mount from the file's top node down: the export's turn from Blender's
        // Z-up to SceneKit's Y-up lives on a transform above "M0110".
        var top = root
        while let parent = top.parent, parent !== model.rootNode { top = parent }
        board.addChildNode(top)
        let (lo, hi) = board.boundingBox
        board.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, (lo.y + hi.y) / 2,
                                                (lo.z + hi.z) / 2)
        scene.rootNode.addChildNode(board)

        collect(in: root)
        setUpCamera()
        setUpLights()
    }

    /// The bundled copy in a built app; in a `swift run` build there is no
    /// bundle, so look up from the binary for the repo's own `Resources`.
    private static func resourceURL(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "usdz") { return url }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = dir else { break }
            let candidate = current.appendingPathComponent("Resources/\(name).usdz")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Setup

    /// USD comes in as a transform node with a same-named mesh child, so
    /// names are looked up on the transform, which is the one to move.
    private func xform(_ name: String, in root: SCNNode) -> SCNNode? {
        guard let node = root.childNode(withName: name, recursively: true) else { return nil }
        if node.geometry != nil, let parent = node.parent, parent.name == name { return parent }
        return node
    }

    private func collect(in root: SCNNode) {
        // Materials are copied before the x-ray shader goes on, so it never
        // reaches the parts that should stay solid.
        func xrayable(_ node: SCNNode, into list: inout [SCNMaterial],
                      cache: inout [String: SCNMaterial], haze: CGFloat = 0.03) {
            node.enumerateHierarchy { child, _ in
                guard let geometry = child.geometry else { return }
                geometry.materials = geometry.materials.map { original in
                    let key = original.name ?? "\(ObjectIdentifier(original))"
                    if let copy = cache[key] { return copy }
                    let copy = original.copy() as! SCNMaterial
                    copy.shaderModifiers = [.fragment: Self.xrayShader]
                    copy.setValue(0.0, forKey: "xray")
                    copy.setValue(haze, forKey: "haze")
                    cache[key] = copy
                    list.append(copy)
                    return copy
                }
                // Drawn after the parts inside, so the glass blends over them.
                child.renderingOrder = 10
            }
        }

        var caseCache: [String: SCNMaterial] = [:]
        for name in ["Upper", "Lower"] {
            guard let shell = root.childNode(withName: name, recursively: true) else { continue }
            // Only the shell's own mesh: the keys and switches hang off Upper.
            let meshes = ([shell] + shell.childNodes).filter { $0.name == name && $0.geometry != nil }
            for mesh in meshes { xrayable(mesh, into: &caseMaterials, cache: &caseCache) }
        }

        root.enumerateHierarchy { node, _ in
            guard let name = node.name, name.hasPrefix("Key_"),
                  node.geometry == nil else { return }
            let tag = String(name.dropFirst(4))
            if Self.featuredKeys.contains(tag) {
                var own: [String: SCNMaterial] = [:]
                var list: [SCNMaterial] = []
                // Frosted rather than clear, so the cap still reads as a cap
                // with its switch inside.
                xrayable(node, into: &list, cache: &own, haze: 0.2)
                featuredMaterials[tag] = list
            } else {
                // Solid, but still drawn after the insides, like the glass.
                node.enumerateHierarchy { child, _ in child.renderingOrder = 10 }
            }
            // A material per cap, to paint its legend into, and texture
            // coordinates laid over its top face to paint it with.
            if let mesh = node.childNodes.first(where: { $0.geometry != nil }),
               let geometry = mesh.geometry {
                if !Self.featuredKeys.contains(tag),
                   let own = geometry.firstMaterial?.copy() as? SCNMaterial {
                    geometry.materials = [own]
                }
                if let (faced, face) = Self.withTopFaceUVs(geometry) {
                    faced.materials = geometry.materials
                    mesh.geometry = faced
                    capFaces[tag] = face
                }
                if let material = mesh.geometry?.firstMaterial {
                    material.diffuse.wrapS = .clamp
                    material.diffuse.wrapT = .clamp
                    capMaterials[tag] = material
                }
            }
            let stem = xform("Stem_\(tag)", in: root)
            var down = SCNVector3(0, -1, 0)
            if let sw = xform("Switch_\(tag)", in: root) {
                let d = SCNVector3(sw.position.x - node.position.x,
                                   sw.position.y - node.position.y,
                                   sw.position.z - node.position.z)
                let length = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
                if length > 0 { down = SCNVector3(d.x / length, d.y / length, d.z / length) }
            }
            keys[tag] = Key(cap: node, stem: stem, down: down,
                            rest: node.position, stemRest: stem?.position)
        }

        battery = xform("Battery", in: root)
        if let battery {
            // The real pack is a 10,000 mAh brick, twice the modelled cell
            // each way. Grown from its bottom face, so it stays on the floor.
            let up = simd_normalize(simd_make_float3(battery.simdTransform.columns.2))
            battery.simdPosition += up * (Self.batteryHalfHeight * (Self.batteryScale - 1))
            battery.simdScale *= Self.batteryScale
        }
        buildGauge()
        nano = xform("NiceNano", in: root)
        buildSoli(in: root)
        if let plate = xform("Plate", in: root),
           case let mesh = plate.childNodes.first(where: { $0.geometry != nil }) ?? plate,
           let material = mesh.geometry?.firstMaterial?.copy() as? SCNMaterial {
            mesh.geometry?.firstMaterial = material
            plateMaterial = material
        }
        upper = xform("Upper", in: root)
        upperRest = upper?.position ?? SCNVector3Zero
    }

    /// The cap's top face as modelled in `assets/M0110.blend`: inset from the
    /// footprint at the sides, front and back by these, in metres.
    private static let faceInset = (side: Float(0.0021), front: Float(0.0030), back: Float(0.0014))

    /// The geometry again, with texture coordinates that put 0...1 across its
    /// top face. The walls fall outside that range and, with the texture
    /// clamped, take the colour of the painted face's border.
    ///
    /// The caps are in Blender's axes: x across, y front to back, z up.
    ///
    /// USD brings the caps in as polygons with one normal per corner rather
    /// than per vertex, indexed separately, a layout SceneKit can draw but
    /// that cannot simply have another source added to it. So the mesh is unrolled into triangles, one vertex
    /// per corner, carrying its own position, normal and coordinate.
    private static func withTopFaceUVs(_ geometry: SCNGeometry) -> (SCNGeometry, CGSize)? {
        guard let vertexSource = geometry.sources(for: .vertex).first,
              let normalSource = geometry.sources(for: .normal).first,
              let element = geometry.elements.first, element.primitiveType == .polygon,
              vertexSource.usesFloatComponents, vertexSource.bytesPerComponent == 4,
              normalSource.usesFloatComponents, normalSource.bytesPerComponent == 4
        else { return nil }

        func vectors(_ source: SCNGeometrySource) -> [SIMD3<Float>] {
            source.data.withUnsafeBytes { raw in
                (0..<source.vectorCount).map { i in
                    let base = source.dataOffset + i * source.dataStride
                    return SIMD3(raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                                 raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                                 raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self))
                }
            }
        }
        let points = vectors(vertexSource), normals = vectors(normalSource)

        // A polygon element is the corner count of each polygon, then, for
        // every corner, one index per source: here a vertex, then a normal.
        let indices: [Int] = element.data.withUnsafeBytes { raw in
            let size = element.bytesPerIndex
            let count = raw.count / size
            return (0..<count).map { i in
                switch size {
                case 1: return Int(raw.load(fromByteOffset: i, as: UInt8.self))
                case 2: return Int(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                default: return Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                }
            }
        }
        let polygons = element.primitiveCount
        guard indices.count > polygons else { return nil }
        let counts = indices[0..<polygons]
        let corners = Array(indices[polygons...])
        let total = counts.reduce(0, +)
        guard total > 0, corners.count % total == 0 else { return nil }
        let stride = corners.count / total

        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let x0 = minX + faceInset.side, x1 = maxX - faceInset.side
        let y0 = minY + faceInset.front, y1 = maxY - faceInset.back
        guard x1 > x0, y1 > y0 else { return nil }

        var outPoints: [SCNVector3] = [], outNormals: [SCNVector3] = []
        var outUVs: [CGPoint] = [], triangles: [UInt32] = []
        var corner = 0
        for count in counts {
            let first = outPoints.count
            for k in 0..<count {
                let index = corners[(corner + k) * stride]
                let normalIndex = stride > 1 ? corners[(corner + k) * stride + 1] : index
                guard index < points.count, normalIndex < normals.count else { return nil }
                let p = points[index]
                let n = normals[normalIndex]
                outPoints.append(SCNVector3(p.x, p.y, p.z))
                outNormals.append(SCNVector3(n.x, n.y, n.z))
                // v runs from the back of the cap, which is the top of the image.
                outUVs.append(CGPoint(x: CGFloat((p.x - x0) / (x1 - x0)),
                                      y: CGFloat((y1 - p.y) / (y1 - y0))))
            }
            // A fan: the caps' polygons are all convex.
            for k in 1..<max(1, count - 1) {
                triangles += [UInt32(first), UInt32(first + k), UInt32(first + k + 1)]
            }
            corner += count
        }

        let faced = SCNGeometry(sources: [SCNGeometrySource(vertices: outPoints),
                                          SCNGeometrySource(normals: outNormals),
                                          SCNGeometrySource(textureCoordinates: outUVs)],
                                elements: [SCNGeometryElement(indices: triangles,
                                                              primitiveType: .triangles)])
        return (faced, CGSize(width: CGFloat(x1 - x0), height: CGFloat(y1 - y0)))
    }

    // MARK: - Painting

    /// Every cap's tag, `<position>_<n>`, with `x` for the unmapped Enter.
    var capTags: [String] { Array(keys.keys) }

    /// Colours the case and the plate; the caps are painted one by one.
    func applyPalette(case shell: NSColor, plate: NSColor) {
        for material in caseMaterials { material.diffuse.contents = shell }
        plateMaterial?.diffuse.contents = plate
    }

    func paint(_ tag: String, face: NSImage?) {
        capMaterials[tag]?.diffuse.contents = face
    }

    /// The cap under a point in the view, if there is one.
    func capTag(at point: CGPoint, in view: SCNView) -> String? {
        let hits = view.hitTest(point, options: [
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: true,
        ])
        var node: SCNNode? = hits.first?.node
        while let current = node {
            if let name = current.name, name.hasPrefix("Key_") { return String(name.dropFirst(4)) }
            node = current.parent
        }
        return nil
    }

    /// One press of a cap, for a click on it.
    func tap(_ tag: String) {
        guard let key = keys[tag] else { return }
        run(key, { press(key) }, delay: 0, repeating: false)
    }

    /// Glass that is clear face-on and bright at grazing angles, the way an
    /// x-ray outline reads. `xray` runs 0 (the plastic as modelled) to 1;
    /// `haze` is how much is left of a surface seen face-on.
    private static let xrayShader = """
    #pragma arguments
    float xray;
    float haze;
    #pragma transparent
    #pragma body
    float facing = abs(dot(normalize(_surface.normal), normalize(_surface.view)));
    float rim = pow(1.0 - saturate(facing), 2.2);
    float alpha = haze + 0.42 * rim;
    float3 glass = float3(0.55, 0.80, 1.0) * (0.25 + 0.9 * rim);
    _output.color.rgb = mix(_output.color.rgb, glass * alpha, xray);
    _output.color.a = mix(_output.color.a, alpha, xray);
    """

    private func setUpCamera() {
        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 34
        camera.zNear = 0.005
        camera.zFar = 10
        cameraNode.camera = camera
        scene.rootNode.addChildNode(rig)
        rig.addChildNode(sway)
        sway.addChildNode(cameraNode)
    }

    private func setUpLights() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 260
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 950
        key.light!.castsShadow = true
        key.light!.shadowMode = .deferred
        key.light!.shadowRadius = 4
        key.light!.shadowColor = NSColor(white: 0, alpha: 0.45)
        key.eulerAngles = SCNVector3(-1.0, -0.6, 0)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        rim.light!.intensity = 380
        rim.light!.color = NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1)
        rim.eulerAngles = SCNVector3(-0.4, 2.6, 0)
        scene.rootNode.addChildNode(rim)
    }

    // MARK: - Focus

    /// How much of the board is glass. Levels run 0 (solid) to 1.
    private struct Look: Equatable {
        var caseXray: CGFloat
        var featured: [String: CGFloat]
        /// Lift everything off the bottom shell to show the boards in it.
        var exploded = false
    }

    private func look(for focus: BoardFocus) -> Look {
        switch focus {
        case .editor, .overview, .popup: return Look(caseXray: 0, featured: [:])
        case .gestures, .battery, .radio: return Look(caseXray: 1, featured: [:], exploded: true)
        }
    }

    private struct Pose {
        var target: SCNVector3
        /// Degrees: yaw round the vertical, pitch below the horizon.
        var yaw: CGFloat
        var pitch: CGFloat
        var distance: CGFloat
    }

    /// A node's position in the board's (centred) space, since that is the
    /// space the rig sits in.
    private func target(_ node: SCNNode?, lift: CGFloat = 0) -> SCNVector3 {
        guard let node else { return SCNVector3Zero }
        var p = node.worldPosition
        p.y += lift
        return p
    }

    private func pose(for focus: BoardFocus) -> Pose {
        switch focus {
        case .editor:
            // Far enough back that the whole case, its near corners included,
            // fits the editor's wide, short box with a margin all round.
            return Pose(target: SCNVector3(0, -0.004, -0.014), yaw: 0, pitch: 52, distance: 0.76)
        case .overview:
            return Pose(target: SCNVector3(0, 0, 0.01), yaw: 0, pitch: 34, distance: 0.62)
        case .popup:
            return Pose(target: SCNVector3(0, 0, 0.01), yaw: -22, pitch: 30, distance: 0.58)
        case .gestures:
            // From low inside the case, behind the module's shoulder,
            // looking out through the right wall: the module, the waves
            // and the hand beyond, the way Soli's own drawing lays them out.
            var centre = target(soli, lift: 0.012)
            centre.x += 0.045
            return Pose(target: centre, yaw: -38.7, pitch: 25.3, distance: 0.27)
        case .battery:
            return Pose(target: target(battery), yaw: -22, pitch: 36, distance: 0.30)
        case .radio:
            return Pose(target: target(nano), yaw: 26, pitch: 38, distance: 0.21)
        }
    }

    func setFocus(_ focus: BoardFocus, animated: Bool) {
        guard focus != self.focus else { return }
        self.focus = focus
        resetEffects()

        let pose = pose(for: focus)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 1.15 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.15, 1)
        rig.position = pose.target
        rig.eulerAngles = SCNVector3(-pose.pitch * .pi / 180, pose.yaw * .pi / 180, 0)
        cameraNode.position = SCNVector3(0, 0, pose.distance)
        sway.eulerAngles = SCNVector3Zero
        let look = look(for: focus)
        if let upper {
            // Up and back, out of the way of a camera looking down from the
            // front.
            upper.position = upperRest
            if look.exploded {
                var lifted = upper.worldPosition
                lifted.y += 0.16
                lifted.z -= 0.15
                upper.worldPosition = lifted
            }
        }
        SCNTransaction.commit()

        // Turning back to solid waits until the camera has mostly pulled
        // out: solid too soon and the close-up fills with the case's cream
        // inside.
        let solidifying = look.caseXray < self.look.caseXray
        // And then goes quickly: half glass, half cream is a frame worth
        // passing through, not one to linger on.
        fade(to: look, duration: animated ? (solidifying ? 0.28 : 0.7) : 0,
             delay: animated && solidifying ? 0.6 : 0)

        // Let the camera land before anything starts moving.
        let settle = animated ? 0.9 : 0.2
        switch focus {
        case .editor, .overview: typeName(after: settle)
        case .popup: drift()
        case .gestures: scan()
        case .battery: showGauge(animated: true)
        case .radio: radiate()
        }
    }

    private func resetEffects() {
        for key in keys.values {
            key.cap.removeAction(forKey: "focus")
            key.cap.position = key.rest
            if let stem = key.stem, let rest = key.stemRest {
                stem.removeAction(forKey: "focus")
                stem.position = rest
            }
        }
        sway.removeAction(forKey: "focus")
        gaugeSegments.forEach { $0.removeAction(forKey: "gauge") }
        showGauge(animated: false)
        effects.forEach { $0.removeFromParentNode() }
        effects.removeAll()
    }

    private func fade(to target: Look, duration: TimeInterval, delay: TimeInterval = 0) {
        let from = look
        let tags = Set(from.featured.keys).union(target.featured.keys)
        let apply: (CGFloat) -> Void = { [weak self] t in
            guard let self else { return }
            func set(_ materials: [SCNMaterial], _ value: CGFloat) {
                for m in materials {
                    m.setValue(value, forKey: "xray")
                    m.writesToDepthBuffer = value < 0.01
                }
            }
            let caseLevel = from.caseXray + (target.caseXray - from.caseXray) * t
            set(self.caseMaterials, caseLevel)
            var featured: [String: CGFloat] = [:]
            for tag in tags {
                let a = from.featured[tag] ?? 0, b = target.featured[tag] ?? 0
                featured[tag] = a + (b - a) * t
                set(self.featuredMaterials[tag] ?? [], featured[tag]!)
            }
            self.look = Look(caseXray: caseLevel, featured: featured.filter { $0.value > 0 },
                             exploded: target.exploded)
        }
        guard duration > 0 else { apply(1); return }
        board.runAction(.sequence([.wait(duration: delay), .customAction(duration: duration) { _, elapsed in
            let t = min(1, CGFloat(elapsed) / CGFloat(duration))
            apply(t * t * (3 - 2 * t))
        }]), forKey: "xray")
    }

    // MARK: - Animations

    /// One key going down and back up, and its stem with it.
    private func press(_ key: Key, hold: TimeInterval = 0, down: TimeInterval = 0.07,
                       up: TimeInterval = 0.18) -> (cap: SCNAction, stem: SCNAction) {
        let d = Self.travel
        let by = SCNVector3(key.down.x * d, key.down.y * d, key.down.z * d)
        func one() -> SCNAction {
            let fall = SCNAction.move(by: by, duration: down)
            fall.timingMode = .easeIn
            let rise = SCNAction.move(by: SCNVector3(-by.x, -by.y, -by.z), duration: up)
            rise.timingMode = .easeOut
            return .sequence([fall, .wait(duration: hold), rise])
        }
        return (one(), one())
    }

    private func run(_ key: Key, _ make: () -> (cap: SCNAction, stem: SCNAction),
                     delay: TimeInterval, repeating: Bool, gap: TimeInterval = 0) {
        let (cap, stem) = make()
        func wrap(_ action: SCNAction) -> SCNAction {
            let body = SCNAction.sequence([action, .wait(duration: gap)])
            return .sequence([.wait(duration: delay), repeating ? .repeatForever(body) : body])
        }
        key.cap.runAction(wrap(cap), forKey: "focus")
        key.stem?.runAction(wrap(stem), forKey: "focus")
    }

    /// The board typing its own name, M-0-1-1-0, once.
    private func typeName(after delay: TimeInterval) {
        // M, 0 and 1 by firmware position; the second 1 is the same key again.
        let strokes = ["60_0", "10_0", "1_0", "1_0", "10_0"]
        var times: [String: [TimeInterval]] = [:]
        for (n, tag) in strokes.enumerated() {
            times[tag, default: []].append(delay + Double(n) * 0.24)
        }
        for (tag, starts) in times {
            guard let key = keys[tag] else { continue }
            var cap: [SCNAction] = [], stem: [SCNAction] = []
            var clock: TimeInterval = 0
            for start in starts {
                let stroke = press(key, down: 0.06, up: 0.14)
                let wait = SCNAction.wait(duration: max(0, start - clock))
                cap += [wait, stroke.cap]
                stem += [wait, stroke.stem]
                clock = start + 0.2
            }
            key.cap.runAction(.sequence(cap), forKey: "focus")
            key.stem?.runAction(.sequence(stem), forKey: "focus")
        }
    }

    /// A slow look from side to side, for the pane with nothing in particular
    /// to point at.
    private func drift() {
        let left = SCNAction.rotateTo(x: 0, y: 0.12, z: 0, duration: 5)
        left.timingMode = .easeInEaseOut
        let right = SCNAction.rotateTo(x: 0, y: -0.12, z: 0, duration: 5)
        right.timingMode = .easeInEaseOut
        sway.runAction(.repeatForever(.sequence([left, right])), forKey: "focus")
    }

    // MARK: - Battery gauge

    /// Ten segments on the cell's top face, in its own axes (Blender's: x
    /// along the cell, z up), so they sit flat on it however the case is
    /// tilted.
    private func buildGauge() {
        guard let battery else { return }
        let count = 10, pitch: CGFloat = 0.0042, width: CGFloat = 0.0034
        let track = SCNNode(geometry: SCNBox(width: CGFloat(count) * pitch + 0.002, height: 0.014,
                                             length: 0.0004, chamferRadius: 0.0004))
        track.geometry?.firstMaterial = Self.flat(NSColor(white: 0.08, alpha: 1))
        track.position = SCNVector3(0, 0, 0.0032)
        battery.addChildNode(track)
        for i in 0..<count {
            let segment = SCNNode(geometry: SCNBox(width: width, height: 0.011,
                                                   length: 0.0006, chamferRadius: 0.0003))
            segment.geometry?.firstMaterial = Self.flat(.black)
            segment.position = SCNVector3((CGFloat(i) - CGFloat(count - 1) / 2) * pitch, 0, 0.0035)
            battery.addChildNode(segment)
            gaugeSegments.append(segment)
        }
        showGauge(animated: false)
    }

    private static func flat(_ colour: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = colour
        return material
    }

    /// The level the gauge shows, and the colour it shows it in: red at or
    /// under the low-battery alert, amber until the alert re-arms, green above.
    /// Nil is no reading, which leaves every segment dark.
    func setBattery(_ level: Int?, low: Int, rearm: Int) {
        let colour: NSColor
        switch level ?? 100 {
        case ...low: colour = NSColor(srgbRed: 0.93, green: 0.30, blue: 0.26, alpha: 1)
        case ...rearm: colour = NSColor(srgbRed: 0.96, green: 0.70, blue: 0.22, alpha: 1)
        default: colour = NSColor(srgbRed: 0.35, green: 0.86, blue: 0.42, alpha: 1)
        }
        let isLow = level.map { $0 <= low } ?? false
        guard level != batteryLevel || colour != gaugeColour || isLow != gaugeLow else { return }
        batteryLevel = level
        gaugeColour = colour
        gaugeLow = isLow
        showGauge(animated: false)
    }

    /// Lights one segment per tenth of charge, rounding up so any charge at all
    /// shows. Animated, they fill from empty, the last one blinking when low.
    private func showGauge(animated: Bool) {
        let lit = batteryLevel.map { Int((Double($0) / 10).rounded(.up)) } ?? 0
        let dim = NSColor(white: 0.16, alpha: 1)
        let low = gaugeLow
        for (i, segment) in gaugeSegments.enumerated() {
            let on = i < lit
            guard let material = segment.geometry?.firstMaterial else { continue }
            segment.removeAction(forKey: "gauge")
            if !animated {
                material.diffuse.contents = on ? gaugeColour : dim
                continue
            }
            material.diffuse.contents = dim
            guard on else { continue }
            let colour = gaugeColour
            var steps: [SCNAction] = [.wait(duration: 0.5 + Double(i) * 0.09),
                                      .run { _ in material.diffuse.contents = colour }]
            if low && i == lit - 1 {
                steps.append(.repeatForever(.sequence([
                    .wait(duration: 0.5), .run { _ in material.diffuse.contents = dim },
                    .wait(duration: 0.5), .run { _ in material.diffuse.contents = colour },
                ])))
            }
            segment.runAction(.sequence(steps), forKey: "gauge")
        }
    }

    /// Rings going out from the radio, flat to the desk.
    private func radiate() {
        guard let nano else { return }
        let origin = nano.worldPosition
        for index in 0..<3 {
            let torus = SCNTorus(ringRadius: 0.012, pipeRadius: 0.0005)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor(srgbRed: 0.45, green: 0.75, blue: 1, alpha: 1)
            material.emission.contents = NSColor(srgbRed: 0.45, green: 0.75, blue: 1, alpha: 1)
            material.writesToDepthBuffer = false
            torus.firstMaterial = material
            let ring = SCNNode(geometry: torus)
            ring.position = SCNVector3(origin.x, origin.y + 0.004, origin.z)
            ring.renderingOrder = 20
            ring.opacity = 0
            scene.rootNode.addChildNode(ring)
            effects.append(ring)

            let period: TimeInterval = 2.1
            let wave = SCNAction.customAction(duration: period) { node, elapsed in
                let t = CGFloat(elapsed) / CGFloat(period)
                let s = 0.3 + 3.2 * t
                node.scale = SCNVector3(s, s, s)
                node.opacity = (1 - t) * min(1, t * 6)
            }
            ring.runAction(.sequence([.wait(duration: Double(index) * period / 3),
                                      .repeatForever(wave)]))
        }
    }

    // MARK: - Soli radar

    /// The Soli radar board, standing against the inside of the case's
    /// right wall: a small black PCB with the radar chip and its gold
    /// antenna pads, a few passives, and its connector along the bottom
    /// edge, chip side in. In the model's own Blender axes (z up, the floor
    /// rising toward the front); the node sits on the floor below the
    /// board's centre.
    private func buildSoli(in root: SCNNode) {
        // The right wall's inner face, measured off the lower shell.
        let wall: CGFloat = 0.1495
        let thickness: CGFloat = 0.0012, side: CGFloat = 0.018
        let y: CGFloat = 0
        let node = SCNNode()
        node.name = "Soli"
        node.position = SCNVector3(wall - thickness / 2, y, 0.0128 - 0.2036 * y)
        node.eulerAngles = SCNVector3(-11.508 * .pi / 180, 0, 0)

        // Everything on the board is placed on its inward face, x = 0 at the
        // face, y across, z up from the floor.
        // Scaled to stand under the wall's rim, about 12.5 mm above the
        // floor here; at full size it stood out over the top of the case.
        let board = SCNNode()
        board.scale = SCNVector3(1, Self.soliScale, Self.soliScale)
        board.position = SCNVector3(0, 0, side * Self.soliScale / 2 + 0.0012)
        node.addChildNode(board)
        let face = -thickness / 2
        func part(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, at y: CGFloat, _ z: CGFloat,
                  _ material: SCNMaterial, chamfer: CGFloat = 0.0001) {
            let n = SCNNode(geometry: SCNBox(width: d, height: w, length: h, chamferRadius: chamfer))
            n.geometry?.firstMaterial = material
            n.position = SCNVector3(face - d / 2, y, z)
            board.addChildNode(n)
        }

        let pcb = SCNNode(geometry: SCNBox(width: thickness, height: side, length: side,
                                           chamferRadius: 0.0004))
        pcb.geometry?.firstMaterial = Self.matte(NSColor(srgbRed: 0.05, green: 0.07, blue: 0.08, alpha: 1))
        board.addChildNode(pcb)

        let gold = SCNMaterial()
        gold.lightingModel = .physicallyBased
        gold.diffuse.contents = NSColor(srgbRed: 0.95, green: 0.74, blue: 0.36, alpha: 1)
        gold.metalness.contents = 0.95
        gold.roughness.contents = 0.25
        let mold = SCNMaterial()
        mold.lightingModel = .physicallyBased
        mold.diffuse.contents = NSColor(white: 0.04, alpha: 1)
        mold.roughness.contents = 0.45
        let ceramic = Self.matte(NSColor(srgbRed: 0.62, green: 0.52, blue: 0.40, alpha: 1))
        let silver = SCNMaterial()
        silver.lightingModel = .physicallyBased
        silver.diffuse.contents = NSColor(white: 0.8, alpha: 1)
        silver.metalness.contents = 1
        silver.roughness.contents = 0.3

        // The radar chip, with its antennas in the package: one transmitter
        // and three receivers in an L, gold squares on its face.
        part(0.0065, 0.005, 0.0009, at: 0, 0.0025, mold, chamfer: 0.0002)
        for (py, pz) in [(-0.0018, 0.0038), (0.0, 0.0038), (0.0018, 0.0038), (0.0018, 0.002)]
            as [(CGFloat, CGFloat)] {
            let pad = SCNNode(geometry: SCNBox(width: 0.0001, height: 0.0012, length: 0.0012, chamferRadius: 0))
            pad.geometry?.firstMaterial = gold
            pad.position = SCNVector3(face - 0.00095, py, pz)
            board.addChildNode(pad)
        }
        // A pin-1 dot.
        part(0.0005, 0.0005, 0.0001, at: -0.0027, 0.0006, gold)

        // Passives round it, a crystal, and the regulator.
        for (py, pz) in [(-0.0055, 0.002), (-0.0055, 0.0035), (0.0055, 0.002), (0.0055, 0.0035),
                         (-0.0045, -0.001), (0.0045, -0.001)] as [(CGFloat, CGFloat)] {
            part(0.001, 0.0005, 0.0005, at: py, pz, ceramic)
        }
        part(0.0032, 0.0025, 0.0008, at: -0.004, -0.0045, silver, chamfer: 0.0003)
        part(0.0028, 0.0028, 0.0008, at: 0.0035, -0.0045, mold, chamfer: 0.0001)

        // Gold edge pads and the connector along the bottom.
        for i in 0..<8 {
            part(0.0009, 0.0014, 0.00005, at: -0.0063 + CGFloat(i) * 0.0018, -0.0078, gold)
        }
        part(0.012, 0.0028, 0.0022, at: 0, -0.0068, Self.matte(NSColor(white: 0.92, alpha: 1)), chamfer: 0.0002)

        root.addChildNode(node)
        soli = node
    }

    /// The Soli board's size against the case, and the height of its radar
    /// chip off the floor, where the waves start.
    private static let soliScale: CGFloat = 0.55
    private static let soliChipHeight = Float(0.018 * soliScale / 2 + 0.0012 + 0.0025 * soliScale)

    private static func matte(_ colour: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = colour
        material.roughness.contents = 0.6
        return material
    }

    /// Light that adds rather than covers, and never hides what is behind it.
    private static func glow(_ colour: NSColor, _ contents: Any? = nil) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = contents ?? colour
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        return material
    }

    /// The radar at work, seen from overhead: the module lit up through
    /// the ghosted keys, and fine wavy fronts rolling out of it to the right,
    /// a Wi-Fi symbol on its side, toward a hand off the case's edge rubbing
    /// thumb against finger, the micro-gesture Soli was made to read.
    private func scan() {
        guard let soli else { return }
        let stage = SCNNode()
        soli.addChildNode(stage)
        effects.append(stage)
        let blue = NSColor(srgbRed: 0.52, green: 0.80, blue: 1, alpha: 1)

        // The wavefronts, in 3D: wavy domes rolling out of the chip through
        // the wall, each one a fan of wavy arcs turned about the beam's
        // axis, thinning as they go.
        let fan = SCNNode()
        fan.position = SCNVector3(0, 0, Self.soliChipHeight)
        stage.addChildNode(fan)
        let domes = Self.waveDomes
        let count = 8
        for _ in 0..<count {
            let dome = SCNNode()
            dome.renderingOrder = 40
            fan.addChildNode(dome)
        }
        let period: TimeInterval = 3.2
        let roll: (SCNNode, Double) -> Void = { node, t in
            for (i, dome) in node.childNodes.enumerated() {
                let u = (Double(i) / Double(count) + t).truncatingRemainder(dividingBy: 1)
                dome.geometry = domes[min(domes.count - 1, Int(u * Double(domes.count)))]
                let fadeIn: Double = min(1, u * 10)
                dome.opacity = CGFloat(fadeIn * (1 - u) * 0.75)
            }
        }
        roll(fan, 0)
        fan.runAction(.repeatForever(.customAction(duration: period) { node, elapsed in
            roll(node, Double(elapsed) / period)
        }))

        let hand = Self.hand()
        // Just outside the wall, the forearm coming from the front and the
        // fist pointing to the keyboard's top edge, palm down and thumb
        // toward the case: the sculpt is upright, so lay it forward, then
        // roll it a quarter turn about its knuckles.
        hand.position = SCNVector3(0.08, -0.006, 0.016)
        hand.simdOrientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
            * simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        hand.scale = SCNVector3(0.62, 0.62, 0.62)
        stage.addChildNode(hand)
    }

    /// The wavefronts, one geometry per step of their travel: at each
    /// radius, wavy arcs fanning ±40° off +x, in planes turned about the x
    /// axis, so together they make a wavy dome. Built once, swapped in as
    /// each front rolls out, since rebuilding them every frame is slow.
    private static let waveDomes: [SCNGeometry] = {
        let steps = 60, planes = 5
        let material = glow(NSColor(srgbRed: 0.52, green: 0.80, blue: 1, alpha: 1))
        return (0..<steps).map { step in
            let r: Double = 0.005 + 0.05 * Double(step) / Double(steps - 1)
            let span: Double = 1.1
            let count = 24 + Int(r * 1200)
            var vertices: [SCNVector3] = []
            var indices: [Int32] = []
            for plane in 0..<planes {
                let phi = Double.pi * Double(plane) / Double(planes)
                let (c, s) = (cos(phi), sin(phi))
                var points: [(Double, Double)] = []
                for k in 0...count {
                    let angle: Double = -span / 2 + span * Double(k) / Double(count)
                    let wiggle: Double = 0.0007 * sin(r * angle * 1800 + Double(plane))
                    points.append((cos(angle) * (r + wiggle), sin(angle) * (r + wiggle)))
                }
                let ribbon = ribbonVertices(points, width: 0.0005)
                let base = Int32(vertices.count)
                // Turn the x-z ribbon about x into this plane.
                vertices += ribbon.vertices.map { v in
                    SCNVector3(v.x, v.y * CGFloat(c) - v.z * CGFloat(s), v.y * CGFloat(s) + v.z * CGFloat(c))
                }
                indices += ribbon.indices.map { $0 + base }
            }
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                       elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
            geometry.firstMaterial = material
            return geometry
        }
    }()

    /// A flat ribbon along a line in the x-z plane, so a line reads at a
    /// set width rather than SceneKit's one pixel.
    private static func ribbon(_ points: [(Double, Double)], width: Double) -> SCNGeometry {
        let (vertices, indices) = ribbonVertices(points, width: width)
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    private static func ribbonVertices(_ points: [(Double, Double)],
                                       width: Double) -> (vertices: [SCNVector3], indices: [Int32]) {
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        for (i, p) in points.enumerated() {
            let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
            let dx = b.0 - a.0, dz = b.1 - a.1
            let length = max(sqrt(dx * dx + dz * dz), 1e-9)
            let nx = -dz / length * width / 2, nz = dx / length * width / 2
            vertices.append(SCNVector3(p.0 + nx, 0, p.1 + nz))
            vertices.append(SCNVector3(p.0 - nx, 0, p.1 - nz))
            if i > 0 {
                let v = Int32(i * 2)
                indices += [v - 2, v - 1, v, v - 1, v + 1, v]
            }
        }
        return (vertices, indices)
    }

    /// The sculpted hand from `tools/make-hand.py`: an upright fist, palm
    /// toward -x, its thumb rubbing back and forth along the index finger.
    private static func hand() -> SCNNode {
        let hand = SCNNode()
        guard let url = resourceURL("Hand"), let scene = try? SCNScene(url: url) else { return hand }
        let skin = SCNMaterial()
        skin.lightingModel = .physicallyBased
        // Warmer and brighter than the glass case, so it reads as a solid
        // thing beyond it rather than more of the x-ray.
        skin.diffuse.contents = NSColor(srgbRed: 0.86, green: 0.78, blue: 0.72, alpha: 1)
        skin.roughness.contents = 0.55
        for name in ["Hand", "Thumb"] {
            guard let mesh = scene.rootNode.childNode(withName: name, recursively: true) else { continue }
            mesh.removeFromParentNode()
            mesh.geometry?.materials = [skin]
            // Drawn after the waves, which write no depth, so the hand covers
            // them wherever it is in the way rather than glowing through.
            mesh.renderingOrder = 50
            hand.addChildNode(mesh)
            guard name == "Thumb" else { continue }
            // Pivot at the thumb's first knuckle, where it meets the hand,
            // so the tip slides along the index finger toward its knuckle.
            let base = SCNVector3(-0.017, -0.039, -0.012)
            mesh.pivot = SCNMatrix4MakeTranslation(base.x, base.y, base.z)
            mesh.position = base
            let out = SCNAction.rotateBy(x: 0, y: 0.16, z: 0, duration: 0.3)
            out.timingMode = .easeInEaseOut
            mesh.runAction(.repeatForever(.sequence([out, out.reversed(), .wait(duration: 0.12)])))
        }
        return hand
    }
}

/// The stage in a panel, with what it is looking at underneath.
struct BoardStageView: View {
    let focus: BoardFocus
    /// False while the stage is off screen, so it stops rendering. The view
    /// is hidden outright too: an SCNView draws through Metal, and SwiftUI
    /// fading or resizing it does not stop it flashing a frame of the board.
    var active = true
    /// The keyboard's last battery reading, nil when it is not connected.
    var battery: Int?
    @AppStorage("lowThreshold") private var lowThreshold: Int = 20
    @AppStorage("rearmThreshold") private var rearmThreshold: Int = 30
    @Environment(\.classicSnapshot) private var snapshot

    /// The battery focus says how charged the cell is, in words as well as
    /// on the gauge.
    private var detail: String? {
        guard focus == .battery else { return nil }
        guard let battery else { return "Not connected" }
        let state = battery <= lowThreshold ? "Low"
            : battery <= rearmThreshold ? "Getting low" : "Charged"
        return "\(battery)% · \(state)"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            if snapshot {
                // ImageRenderer cannot draw an SCNView.
                Color.clear
            } else {
                StageSceneView(focus: focus, active: active,
                               battery: (battery, lowThreshold, rearmThreshold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(focus.caption)
                    .font(Theme.small.weight(.semibold))
                    .foregroundStyle(Theme.text)
                if let detail {
                    Text(detail)
                        .font(Theme.small.monospacedDigit())
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(14)
            .animation(.easeInOut(duration: 0.2), value: focus)
        }
        .background(Theme.panel, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.panelStroke, lineWidth: 1))
    }
}

private struct StageSceneView: NSViewRepresentable {
    let focus: BoardFocus
    let active: Bool
    let battery: (level: Int?, low: Int, rearm: Int)

    final class Coordinator {
        let stage = BoardStage()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        if let stage = context.coordinator.stage {
            view.scene = stage.scene
            view.pointOfView = stage.cameraNode
            stage.paintBlank()
            stage.setBattery(battery.level, low: battery.low, rearm: battery.rearm)
            stage.setFocus(focus, animated: false)
        }
        view.isPlaying = active
        view.isHidden = !active
        if active { BoardStage.lastShown = focus }
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        view.isPlaying = active
        if active && view.isHidden { view.fadeIn() }
        view.isHidden = !active
        // Hidden behind the Keyboard pane it keeps what it showed last, for
        // that pane to fly back from; hidden anywhere else, nothing was shown.
        if active { BoardStage.lastShown = focus } else if focus != .editor { BoardStage.lastShown = nil }
        context.coordinator.stage?.setBattery(battery.level, low: battery.low, rearm: battery.rearm)
        context.coordinator.stage?.setFocus(focus, animated: true)
    }
}

extension SCNView {
    /// Arrive from transparent rather than popping in. Only the alpha moves:
    /// the view is already at its size, which is what kept this from
    /// smearing the way a SwiftUI resize of it does.
    func fadeIn(duration: TimeInterval = 0.32) {
        alphaValue = 0
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        }
    }
}
