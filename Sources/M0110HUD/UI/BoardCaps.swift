import SceneKit
import CoreGraphics

/// The keycaps as solids standing in the well, one box per key.
///
/// Until this existed the caps were painted onto the well floor, so the board
/// had no keys in its silhouette: edge-on it was a smooth slab, and from above
/// the caps had no thickness, no shadow between them, and nothing catching the
/// light differently from the case. A keyboard whose keys do not stick up is
/// the kind of wrong that survives every other correction.
///
/// Positions come from `M0110Layout.ansi`, the same table `BoardArtView` draws
/// from, so the solid caps and the flat art cannot end up on different grids.
enum BoardCaps {
    /// Cap height, 19 mm, which with `BoardHull.wellDepth` at 34 leaves them
    /// standing about 12.6 mm proud of the bezel.
    ///
    /// This is a balance between two views of the board, and both were checked.
    /// In profile the caps should be roughly a third of the total height, which
    /// 110 blew past -- at 21 mm they took about 60% and the board read as a
    /// wedge of keycaps. But 70 went too far the other way: from above, where
    /// the HUD actually shows the board, the caps lost their sides and the top
    /// flattened out again. 55 was worse still, clearing the bezel by 4 mm.
    static let capHeight: CGFloat = 100

    /// `deckY` gives the well floor's height at a depth, since the floor is
    /// raked and every row sits a little higher than the one in front of it.
    static func make(hull: BoardHull, u: CGFloat,
                     deckY: (CGFloat) -> CGFloat) -> [SCNNode] {
        let w = hull.footprint.width / u
        let d = hull.footprint.height / u
        let xL = -w / 2, zB = -d / 2
        let gap = BoardCase.keyGap
        let side = BoardCase.Bezel.m0110.side
        let top = BoardCase.Bezel.m0110.top
        let height = capHeight / u

        // Darker than the case by a clear margin. The caps and the bezel used
        // to sit within a few percent of each other, so at HUD size the keys
        // dissolved into the plastic around them; the separation is doing more
        // work here than the geometry is.
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

        // The caps stand perpendicular to the deck they are mounted on, not
        // to the desk. Left upright on a raked floor they climb it as a
        // staircase, and the board's profile reads as a ramp rather than as a
        // case with keys on it.
        let rake = atan2(hull.backHeight - hull.frontHeight, hull.footprint.height)

        return M0110Layout.ansi.map { key in
            let kw = (CGFloat(key.attrs.width) - gap) / u
            let kd = (CGFloat(key.attrs.height) - gap) / u
            // Art coordinates: x grows right from the case's left edge, y grows
            // toward the front. `BoardWedge` maps the art the same way, so the
            // conversion to scene units is the same one its texture uses.
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
            // Raised along the deck's normal rather than straight up, so a
            // tilted cap still meets the floor instead of sinking a corner
            // into it.
            node.position = SCNVector3(x,
                                       deckY(z) + (height / 2) * cos(rake),
                                       z + (height / 2) * sin(rake))
            return node
        }
    }
}
