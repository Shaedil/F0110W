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
    private let topMaterial = SCNMaterial()

    /// Case beige, matching `Theme.caseFlat`. The sides of the real case are
    /// the same plastic as the top, just turned away from the light.
    private static let caseCream = NSColor(srgbRed: 0.839, green: 0.824, blue: 0.765, alpha: 1)

    init() {
        scene.rootNode.addChildNode(boardNode)
        boardNode.addChildNode(SCNNode(geometry: makeBox()))
        scene.rootNode.addChildNode(makeCamera())
        for light in makeLights() { scene.rootNode.addChildNode(light) }
    }

    /// `BoardHull` measures in hundredths of a key unit; the scene works in
    /// scene units, so everything divides by the same constant and the
    /// proportions carry over untouched.
    private func makeBox() -> SCNBox {
        let hull = BoardHull.m0110
        let u: CGFloat = 1000
        let width = hull.footprint.width / u
        let depth = hull.footprint.height / u
        // A box cannot be a wedge, so the solid takes the mean of the front and
        // back heights and loses the case's 12° rake.
        let height = hull.meanHeight / u

        let box = SCNBox(width: width, height: height, length: depth,
                         chamferRadius: min(width, depth) * 0.02)

        let cream = SCNMaterial()
        cream.diffuse.contents = Self.caseCream
        cream.lightingModel = .blinn
        cream.specular.contents = NSColor(white: 0.30, alpha: 1)
        cream.shininess = 0.18

        topMaterial.lightingModel = .blinn
        topMaterial.diffuse.contents = Self.caseCream
        topMaterial.specular.contents = NSColor(white: 0.20, alpha: 1)
        topMaterial.shininess = 0.10

        // SCNBox material order: front, right, back, left, top, bottom.
        box.materials = [cream, cream, cream, cream, topMaterial, cream]
        return box
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
        // 35° up, and far enough back for the *widest* point of the turn rather
        // than the head-on view: a board seen at 30° projects wider than the
        // same board seen square on, so framing it flush at 0° clips its
        // corners for most of every rotation.
        //
        // The elevation is what decides whether it fits vertically. A rotating
        // footprint projects to `depth × sin(elevation)`, so a steeper, more
        // top-down camera, which looks closer to the reference photograph, is
        // the one that sprawls out of a short frame. 35° keeps the top face
        // readable and the sweep inside the slot.
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

    /// Lay the vector art on the top face for a given theme.
    ///
    /// Separate from `init` because the art is built from dynamic colours,
    /// which resolve only once something knows which appearance it is in, and
    /// it has to be redone when that changes under a HUD already on screen.
    @MainActor
    func applyArt(colorScheme: ColorScheme, pixelsWide: CGFloat = 1024) {
        guard let image = BoardArt.topFace(pixelsWide: pixelsWide, colorScheme: colorScheme)
        else { return }
        topMaterial.diffuse.contents = image
    }
}
