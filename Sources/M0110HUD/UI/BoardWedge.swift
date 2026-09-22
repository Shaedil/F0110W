import SceneKit
import CoreGraphics

/// The M0110 case as the solid it actually is: a top face raked up toward the
/// back, and an underside in two levels — a flat rim all the way round, level
/// front to back, with an inset platform standing proud of it that carries the
/// rake and everything printed on the bottom.
///
/// `SCNBox` cannot express any of that, and the box that stood in for it
/// averaged the two heights and threw the rake away — which is the one thing
/// about this keyboard's silhouette anybody recognises. A plain wedge got the
/// profile right but still had a single flat underside, so from below it read
/// as a doorstop rather than as this case.
///
/// `BoardHull` has carried `frontHeight` and `backHeight` all along, measured
/// off the real case, and now carries the rim too, so the numbers stay in one
/// place and only the geometry lives here.
///
/// Built by hand from quads rather than by extruding a profile, because
/// `SCNShape` gives its extrusion one material for every side at once and the
/// top and the platform each need their own drawing.
enum BoardWedge {
    /// Material slots, in the order `make` emits its geometry elements.
    enum Face: Int, CaseIterable {
        /// The raked top, carrying the board art.
        case top
        /// The platform underside, carrying the underside drawing.
        case underside
        /// The back wall, the tall one, carrying the sockets.
        case back
        /// The seam where the case's two shells meet, and the walls of the key
        /// well. Both are grooves, so they share a material.
        case seam
        /// Everything else: the other three walls, the rim, and the step down
        /// to the platform. All of it is bare case plastic, so it is one
        /// element.
        case shell
    }

    /// Height of the well floor at a given depth, in scene units.
    ///
    /// The floor is raked, so a cap's height depends on which row it is in.
    /// Exposed rather than recomputed by the caller: the caps sitting a
    /// hair above or below the floor they stand on is exactly the sort of
    /// thing two copies of this formula would produce.
    static func deckY(hull: BoardHull, u: CGFloat, z: CGFloat) -> CGFloat {
        let d = hull.footprint.height / u
        let frontH = hull.frontHeight / u
        let backH = hull.backHeight / u
        let zF = d / 2
        let shift = -backH / 2
        return shift + frontH + (backH - frontH) * (zF - z) / d - hull.wellDepth / u
    }

    /// `hull` measures in unit-hundredths; `u` is how many of those make one
    /// scene unit, matching whatever the caller used for the rest of the scene.
    static func make(hull: BoardHull, u: CGFloat) -> SCNGeometry {
        let w = hull.footprint.width / u
        let d = hull.footprint.height / u
        let frontH = hull.frontHeight / u
        let backH = hull.backHeight / u
        let rim = hull.rimWidth / u
        let drop = hull.rimDrop / u
        let well = hull.wellDepth / u
        let lip = hull.lipInset / u
        let inSide = hull.deckInsetSide / u
        let inFront = hull.deckInsetFront / u
        let inBack = hull.deckInsetBack / u

        // Centred on the bounding box, so the barrel roll turns about the
        // middle of the silhouette rather than about the thin end. The box this
        // replaced was symmetrical and got that for free.
        let shift = -backH / 2
        let yPlatform = shift                 // lowest plane, what the feet sit on
        let yRim = shift + drop               // the rim, held clear of the desk

        let xL = -w / 2, xR = w / 2
        // +Z is toward the camera, which is the keyboard's front edge.
        let zB = -d / 2, zF = d / 2
        let ixL = xL + rim, ixR = xR - rim
        let izB = zB + rim, izF = zF - rim
        // The lower shell, set back behind the upper one's overhang.
        let lxL = xL + lip, lxR = xR - lip
        let lzB = zB + lip, lzF = zF - lip
        // The key well, set in by the same bezel the flat art draws.
        let dxL = xL + inSide, dxR = xR - inSide
        let dzB = zB + inBack, dzF = zF - inFront

        /// The raked top surface at a given depth.
        func topY(_ z: CGFloat) -> CGFloat {
            shift + frontH + (backH - frontH) * (zF - z) / d
        }
        func p(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
            SCNVector3(x, y, z)
        }
        // Where the upper shell stops overhanging and the lower one takes over.
        let ySeam = yRim + (topY(zF) - yRim) * hull.seamFraction
        func uv(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        // The shell is bare plastic, so its mapping only has to be sane.
        let plain = [uv(0, 1), uv(1, 1), uv(1, 0), uv(0, 0)]

        // Top corners.
        let tFL = p(xL, topY(zF), zF), tFR = p(xR, topY(zF), zF)
        let tBR = p(xR, topY(zB), zB), tBL = p(xL, topY(zB), zB)
        // The inner rectangle, at rim level and again at platform level.
        let rFL = p(ixL, yRim, izF), rFR = p(ixR, yRim, izF)
        let rBR = p(ixR, yRim, izB), rBL = p(ixL, yRim, izB)
        let cFL = p(ixL, yPlatform, izF), cFR = p(ixR, yPlatform, izF)
        let cBR = p(ixR, yPlatform, izB), cBL = p(ixL, yPlatform, izB)

        // The platform shows the middle of the underside drawing, cropped to
        // the rim rather than squeezed into it, so the feet stay round.
        let uMin = rim / w, uMax = 1 - rim / w
        let vMin = rim / d, vMax = 1 - rim / d

        // The top drawing spans the whole footprint, so the bezel bands and the
        // well floor each take their texture coordinates from their own place
        // in that one image and the drawing stays continuous across the step.
        /// v runs 0 at the back, where the art's function row is, matching the
        /// single top quad this replaced. Computing it from the front instead
        /// flips every top face front-to-back, which reads as the spacebar
        /// migrating to the top of the board.
        func topUV(_ x: CGFloat, _ z: CGFloat) -> CGPoint {
            CGPoint(x: (x - xL) / w, y: (z - zB) / d)
        }
        func topQuad(_ q: [SCNVector3]) -> (corners: [SCNVector3], uv: [CGPoint]) {
            (q, q.map { topUV($0.x, $0.z) })
        }
        // The bezel's inner edge, and the well floor a little below it.
        let eFL = p(dxL, topY(dzF), dzF), eFR = p(dxR, topY(dzF), dzF)
        let eBR = p(dxR, topY(dzB), dzB), eBL = p(dxL, topY(dzB), dzB)
        let fFL = p(dxL, topY(dzF) - well, dzF), fFR = p(dxR, topY(dzF) - well, dzF)
        let fBR = p(dxR, topY(dzB) - well, dzB), fBL = p(dxL, topY(dzB) - well, dzB)

        // Corners run counter-clockwise seen from outside, which is what
        // SceneKit treats as front-facing.
        // The bezel as four bands round the well, then the well floor itself
        // sunk below them. The caps are drawn on that floor, so they now sit
        // *in* the case rather than on a lid.
        let top: [(corners: [SCNVector3], uv: [CGPoint])] = [
            // Wound front-left, front-right, back-right, back-left, the same
            // order as the single top quad these replaced. The bottom-face
            // order points their normals at the desk and they vanish.
            topQuad([p(xL, topY(zF), zF), p(xR, topY(zF), zF),
                     p(xR, topY(dzF), dzF), p(xL, topY(dzF), dzF)]),   // front band
            topQuad([p(xL, topY(dzB), dzB), p(xR, topY(dzB), dzB),
                     p(xR, topY(zB), zB), p(xL, topY(zB), zB)]),       // back band
            topQuad([p(xL, topY(dzF), dzF), p(dxL, topY(dzF), dzF),
                     p(dxL, topY(dzB), dzB), p(xL, topY(dzB), dzB)]),  // left
            topQuad([p(dxR, topY(dzF), dzF), p(xR, topY(dzF), dzF),
                     p(xR, topY(dzB), dzB), p(dxR, topY(dzB), dzB)]),  // right
            topQuad([fFL, fFR, fBR, fBL]),                             // well floor
        ]
        let underside: [(corners: [SCNVector3], uv: [CGPoint])] = [
            ([cFL, cBL, cBR, cFR], [uv(uMin, vMax), uv(uMin, vMin),
                                    uv(uMax, vMin), uv(uMax, vMax)]),
        ]
        // The upper back wall, the tall one, drawn with the sockets on it. It
        // starts at the lip rather than at the rim.
        let back: [(corners: [SCNVector3], uv: [CGPoint])] = [
            ([p(xR, ySeam, zB), p(xL, ySeam, zB), tBL, tBR],
             [uv(0, 1), uv(1, 1), uv(1, 0), uv(0, 0)]),
        ]
        // The seam is real geometry now, so this group is only the well's
        // walls, facing inward so they are seen from above.
        let seam: [(corners: [SCNVector3], uv: [CGPoint])] = [
            ([fFL, fBL, eBL, eFL], plain),
            ([fBR, fFR, eFR, eBR], plain),
            ([fFR, fFL, eFL, eFR], plain),
            ([fBL, fBR, eBR, eBL], plain),
        ]
        let shell: [(corners: [SCNVector3], uv: [CGPoint])] = [
            // The upper shell: full footprint, lip up to the raked top.
            ([p(xL, ySeam, zF), p(xR, ySeam, zF), tFR, tFL], plain),   // front
            ([p(xL, ySeam, zB), p(xL, ySeam, zF), tFL, tBL], plain),   // left
            ([p(xR, ySeam, zF), p(xR, ySeam, zB), tBR, tFR], plain),   // right

            // The lip's underside: the overhang, facing the desk.
            ([p(xL, ySeam, zF), p(xL, ySeam, lzF),
              p(xR, ySeam, lzF), p(xR, ySeam, zF)], plain),
            ([p(xL, ySeam, lzB), p(xL, ySeam, zB),
              p(xR, ySeam, zB), p(xR, ySeam, lzB)], plain),
            ([p(xL, ySeam, lzF), p(xL, ySeam, lzB),
              p(lxL, ySeam, lzB), p(lxL, ySeam, lzF)], plain),
            ([p(lxR, ySeam, lzF), p(lxR, ySeam, lzB),
              p(xR, ySeam, lzB), p(xR, ySeam, lzF)], plain),

            // The lower shell, set back: rim up to the lip.
            ([p(lxL, yRim, lzF), p(lxR, yRim, lzF),
              p(lxR, ySeam, lzF), p(lxL, ySeam, lzF)], plain),
            ([p(lxR, yRim, lzB), p(lxL, yRim, lzB),
              p(lxL, ySeam, lzB), p(lxR, ySeam, lzB)], plain),
            ([p(lxL, yRim, lzB), p(lxL, yRim, lzF),
              p(lxL, ySeam, lzF), p(lxL, ySeam, lzB)], plain),
            ([p(lxR, yRim, lzF), p(lxR, yRim, lzB),
              p(lxR, ySeam, lzB), p(lxR, ySeam, lzF)], plain),

            // The rim: level bands from the lower shell in to the platform.
            ([p(lxL, yRim, lzF), p(lxL, yRim, izF),
              p(lxR, yRim, izF), p(lxR, yRim, lzF)], plain),
            ([p(lxL, yRim, izB), p(lxL, yRim, lzB),
              p(lxR, yRim, lzB), p(lxR, yRim, izB)], plain),
            ([p(lxL, yRim, izF), p(lxL, yRim, izB),
              p(ixL, yRim, izB), p(ixL, yRim, izF)], plain),
            ([p(ixR, yRim, izF), p(ixR, yRim, izB),
              p(lxR, yRim, izB), p(lxR, yRim, izF)], plain),

            // The step down from the rim onto the platform.
            ([cFL, cFR, rFR, rFL], plain),
            ([cBR, cBL, rBL, rBR], plain),
            ([cBL, cFL, rFL, rBL], plain),
            ([cFR, cBR, rBR, rFR], plain),
        ]

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var texture: [CGPoint] = []
        var elements: [SCNGeometryElement] = []

        for group in [top, underside, back, seam, shell] {
            var indices: [Int32] = []
            for quad in group {
                let base = Int32(vertices.count)
                vertices += quad.corners
                normals += Array(repeating: faceNormal(quad.corners), count: 4)
                texture += quad.uv
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
            elements.append(SCNGeometryElement(indices: indices, primitiveType: .triangles))
        }

        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices),
                      SCNGeometrySource(normals: normals),
                      SCNGeometrySource(textureCoordinates: texture)],
            elements: elements)
    }

    /// Taken from the quad's first triangle. Derived rather than written out by
    /// hand: the top face's normal tilts with the rake, and fourteen normals
    /// typed from memory is fourteen chances to light a face from inside the
    /// case.
    private static func faceNormal(_ q: [SCNVector3]) -> SCNVector3 {
        let a = SCNVector3(q[1].x - q[0].x, q[1].y - q[0].y, q[1].z - q[0].z)
        let b = SCNVector3(q[2].x - q[0].x, q[2].y - q[0].y, q[2].z - q[0].z)
        let n = SCNVector3(a.y * b.z - a.z * b.y,
                           a.z * b.x - a.x * b.z,
                           a.x * b.y - a.y * b.x)
        let length = sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
        guard length > 0 else { return SCNVector3(0, 1, 0) }
        return SCNVector3(n.x / length, n.y / length, n.z / length)
    }
}
