import AppKit
import SceneKit
import SwiftUI

/// The 3D M0110: a chamfered solid at the real board's proportions, surfaced
/// with `BoardArtView`'s vector art.
///
/// The model is not an imported asset. Proportions come from `BoardHull`, which
/// derives them from the same layout table the Keys pane draws, and the top
/// face is the same drawing the editor shows, so the board that spins in the
/// HUD and the board you edit keys on cannot be restyled apart.
///
/// Built as a value rather than baked into the view so the same scene can be
/// rendered offscreen for review (`--board-snapshot`) without a HUD, a window,
/// or a screen capture.
struct BoardScene {
    let scene = SCNScene()
    /// The node to turn. Rotating this rather than the geometry keeps the
    /// camera and lights fixed, which is what makes the light sweep across the
    /// case as it goes round.
    let boardNode = SCNNode()
    /// Unit-hundredths to a scene unit. One constant, because the wedge, the
    /// caps and the textures all have to agree about it.
    static let sceneUnit: CGFloat = 1000

    private let topMaterial = SCNMaterial()
    private let bottomMaterial = SCNMaterial()
    private let backMaterial = SCNMaterial()

    /// Case beige, matching `Theme.caseFlat`. The sides of the real case are
    /// the same plastic as the top, just turned away from the light.
    private static let caseCream = NSColor(srgbRed: 0.839, green: 0.824, blue: 0.765, alpha: 1)

    init() {
        scene.rootNode.addChildNode(boardNode)
        boardNode.addChildNode(SCNNode(geometry: makeWedge()))
        // The caps are solids standing in the well, not paint on its floor.
        // They turn with the case, so they hang off the same node.
        let hull = BoardHull.m0110
        for cap in BoardCaps.make(hull: hull, u: Self.sceneUnit,
                                  deckY: { BoardWedge.deckY(hull: hull, u: Self.sceneUnit, z: $0) }) {
            boardNode.addChildNode(cap)
        }
        scene.rootNode.addChildNode(makeCamera())
        for light in makeLights() { scene.rootNode.addChildNode(light) }
    }

    /// `BoardHull` measures in hundredths of a key unit; the scene works in
    /// scene units, so everything divides by the same constant and the
    /// proportions carry over untouched.
    private func makeWedge() -> SCNGeometry {
        let geometry = BoardWedge.make(hull: BoardHull.m0110, u: Self.sceneUnit)

        func cream() -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = Self.caseCream
            m.lightingModel = .blinn
            m.specular.contents = NSColor(white: 0.30, alpha: 1)
            m.shininess = 0.18
            return m
        }

        for face in [topMaterial, bottomMaterial, backMaterial] {
            face.lightingModel = .blinn
            face.diffuse.contents = Self.caseCream
            face.specular.contents = NSColor(white: 0.20, alpha: 1)
            face.shininess = 0.10
        }

        let groove = SCNMaterial()
        groove.diffuse.contents = NSColor(srgbRed: 0.506, green: 0.494, blue: 0.453, alpha: 1)
        groove.lightingModel = .blinn
        groove.specular.contents = NSColor(white: 0.10, alpha: 1)
        groove.shininess = 0.05

        // In `BoardWedge.Face` order: top, underside, back, seam, shell.
        geometry.materials = [topMaterial, bottomMaterial, backMaterial,
                              groove, cream()]
        return geometry
    }

    private func makeCamera() -> SCNNode {
        let camera = SCNCamera()
        // Fix the field of view to the horizontal, then frame the board's long
        // axis in it. Left on the default the framing tracks whichever edge of
        // the view happens to be longer, so the board changes size when the HUD
        // is rescaled, which is what `--scale` does.
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 44
        camera.zNear = 0.01

        let node = SCNNode()
        node.camera = camera
        // 35° up, and far enough back for the tallest pose of the roll.
        //
        // The board turns about its long axis, so its horizontal extent is the
        // case width at every angle and the framing never has to chase it. What
        // moves is the vertical: it sweeps between the case seen edge-on, which
        // is only its thickness, and the full depth of the top face when that
        // comes round to face the camera. 2.4 back clears the tall pose.
        //
        // The elevation is a look rather than a fit. 35° is where the top face
        // reads like the reference photograph instead of like a plan view, and
        // it sets which face leads into the roll.
        node.position = SCNVector3(0, 1.7, 2.4)
        node.look(at: SCNVector3(0, 0, 0))
        return node
    }

    private func makeLights() -> [SCNNode] {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.74, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient

        // One key light, high and to the left, matching the direction the flat
        // drawing is lit from: its chamfers run bright top-left to dark
        // bottom-right, and a light from the other side would fight the texture.
        let key = SCNLight()
        key.type = .directional
        key.color = NSColor(white: 0.80, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-2, 3, 2)
        keyNode.look(at: SCNVector3(0, 0, 0))

        return [ambientNode, keyNode]
    }

    /// Lay the vector art on the two drawn faces for a given theme.
    ///
    /// Separate from `init` because the art is built from dynamic colours,
    /// which resolve only once something knows which appearance it is in, and
    /// it has to be redone when that changes under a HUD already on screen.
    @MainActor
    func applyArt(colorScheme: ColorScheme, pixelsWide: CGFloat = 1024) {
        if let top = BoardArt.topFace(pixelsWide: pixelsWide, colorScheme: colorScheme) {
            topMaterial.diffuse.contents = top
        }
        if let bottom = BoardArt.bottomFace(pixelsWide: pixelsWide, colorScheme: colorScheme) {
            bottomMaterial.diffuse.contents = bottom
        }
        if let back = BoardArt.backFace(pixelsWide: pixelsWide, colorScheme: colorScheme) {
            backMaterial.diffuse.contents = back
        }
    }
}
