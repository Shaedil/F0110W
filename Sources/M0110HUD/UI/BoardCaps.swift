import SceneKit
import CoreGraphics

/// The keycaps as 3D boxes standing in the well, one per key.
/// Positions come from `M0110Layout.ansi`, the same table `BoardArtView` uses.
enum BoardCaps {
    /// Cap height, 19 mm. With `BoardHull.wellDepth` at 34, caps stand about 12.6 mm
    /// above the bezel. Taller caps take over the side profile, and shorter ones
    /// look flat from above, which is how the HUD shows the board.
    static let capHeight: CGFloat = 100

    /// `deckY` gives the well floor's height at a depth, since the floor slopes
    /// up toward the back.
    static func make(hull: BoardHull, u: CGFloat,
                     deckY: (CGFloat) -> CGFloat) -> [SCNNode] {
        let w = hull.footprint.width / u
        let d = hull.footprint.height / u
        let xL = -w / 2, zB = -d / 2
        let gap = BoardCase.keyGap
        let side = BoardCase.Bezel.m0110.side
        let top = BoardCase.Bezel.m0110.top
        let height = capHeight / u

        // Clearly darker than the case, or the keys blend into the bezel at HUD size.
        let top_ = SCNMaterial()
        top_.diffuse.contents = NSColor(srgbRed: 0.639, green: 0.643, blue: 0.604, alpha: 1)
        top_.lightingModel = .blinn
        top_.specular.contents = NSColor(white: 0.22, alpha: 1)
        top_.shininess = 0.12

        let skirt = SCNMaterial()
        skirt.diffuse.contents = NSColor(srgbRed: 0.478, green: 0.482, blue: 0.451, alpha: 1)
        skirt.lightingModel = .blinn
        skirt.specular.contents = NSColor(white: 0.14, alpha: 1)
        skirt.shininess = 0.06

        // Tilt the caps to match the sloped deck. Upright caps on a slope look
        // like stairs.
        let rake = atan2(hull.backHeight - hull.frontHeight, hull.footprint.height)

        return M0110Layout.ansi.map { key in
            let kw = (CGFloat(key.attrs.width) - gap) / u
            let kd = (CGFloat(key.attrs.height) - gap) / u
            // Art coordinates: x grows right from the case's left edge and y grows
            // toward the front, the same mapping `BoardWedge` uses for its texture.
            let artX = side + CGFloat(key.attrs.x) + CGFloat(key.attrs.width) / 2
            let artY = top + CGFloat(key.attrs.y) + CGFloat(key.attrs.height) / 2
            let x = xL + artX / u
            let z = zB + artY / u

            let box = SCNBox(width: kw, height: height, length: kd,
                             chamferRadius: min(kw, kd) * 0.08)
            // SCNBox material order: front, right, back, left, top, bottom.
            box.materials = [skirt, skirt, skirt, skirt, top_, skirt]

            let node = SCNNode(geometry: box)
            node.eulerAngles = SCNVector3(rake, 0, 0)
            // Offset along the deck's normal so a tilted cap sits flush on the floor.
            node.position = SCNVector3(x,
                                       deckY(z) + (height / 2) * cos(rake),
                                       z + (height / 2) * sin(rake))
            return node
        }
    }
}
