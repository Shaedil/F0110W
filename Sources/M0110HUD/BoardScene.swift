import AppKit
import SceneKit
import SwiftUI

/// The 3D M0110: a chamfered solid at the real board's proportions, with `BoardArtView`'s art.
/// Proportions come from `BoardHull`, which uses the same layout table as the Keys pane, so
/// the HUD board and the editor board always match. Built as a value so `--board-snapshot`
/// can render it offscreen without a HUD or window.
struct BoardScene {
    let scene = SCNScene()
    /// The node to rotate. The camera and lights stay fixed, so light moves across the case as it turns.
    let boardNode = SCNNode()
    /// Key-unit hundredths per scene unit. The wedge, caps and textures must all use the same value.
    static let sceneUnit: CGFloat = 1000

    private let topMaterial = SCNMaterial()
    private let bottomMaterial = SCNMaterial()
    private let backMaterial = SCNMaterial()

    /// Matches `Theme.caseFlat`. The real case sides are the same plastic as the top.
    private static let caseCream = NSColor(srgbRed: 0.839, green: 0.824, blue: 0.765, alpha: 1)

    init() {
        scene.rootNode.addChildNode(boardNode)
        boardNode.addChildNode(SCNNode(geometry: makeWedge()))
        // The caps are solid shapes, added to the board node so they rotate with the case.
        let hull = BoardHull.m0110
        for cap in BoardCaps.make(hull: hull, u: Self.sceneUnit,
                                  deckY: { BoardWedge.deckY(hull: hull, u: Self.sceneUnit, z: $0) }) {
            boardNode.addChildNode(cap)
        }
        scene.rootNode.addChildNode(makeCamera())
        for light in makeLights() { scene.rootNode.addChildNode(light) }
    }

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
        // Fix the field of view to the horizontal axis. By default it follows the longer view
        // edge, so the board would change size when `--scale` resizes the HUD.
        camera.projectionDirection = .horizontal
        camera.fieldOfView = 44
        camera.zNear = 0.01

        let node = SCNNode()
        node.camera = camera
        // 35 degrees up and 2.4 back. The board rotates about its long axis, so only its height
        // changes, from edge-on thickness to the full top face. 2.4 back fits the tallest pose.
        // 35 degrees makes the top face look like the reference photo.
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

        // Key light high and to the left, to match the flat drawing's chamfers (bright top-left,
        // dark bottom-right).
        let key = SCNLight()
        key.type = .directional
        key.color = NSColor(white: 0.80, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(-2, 3, 2)
        keyNode.look(at: SCNVector3(0, 0, 0))

        return [ambientNode, keyNode]
    }

    /// Separate from `init` because the art uses dynamic colors that resolve only once the
    /// appearance is known, and it must be redone when the appearance changes on a visible HUD.
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
