import SceneKit
import CoreGraphics

/// The M0110 case geometry: a top surface sloping up toward the back, and an
/// underside with a level rim around a raised platform. Sizes come from `BoardHull`.
///
/// Built from quads by hand because `SCNShape` gives an extrusion one material
/// for all sides, and the top and the platform each need their own texture.
enum BoardWedge {
    /// Material slots, in the order `make` emits its geometry elements.
    enum Face: Int, CaseIterable {
        case top
        case underside
        case back
        /// The key well walls.
        case seam
        /// The other walls, the rim, and the step down to the platform.
        case shell
    }

    /// Height of the well floor at a depth, in scene units. The keycaps use this
    /// so they sit exactly on the sloped floor.
    static func deckY(hull: BoardHull, u: CGFloat, z: CGFloat) -> CGFloat {
        let d = hull.footprint.height / u
        let frontH = hull.frontHeight / u
        let backH = hull.backHeight / u
        let zF = d / 2
        let shift = -backH / 2
        return shift + frontH + (backH - frontH) * (zF - z) / d - hull.wellDepth / u
    }

    /// `u` is how many hundredths of a key unit make one scene unit.
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

        // Center on the bounding box so the roll turns about the middle of the case.
        let shift = -backH / 2
        let yPlatform = shift                 // lowest plane, where the feet sit
        let yRim = shift + drop

        let xL = -w / 2, xR = w / 2
        // +Z is toward the camera, which is the keyboard's front edge.
        let zB = -d / 2, zF = d / 2
        let ixL = xL + rim, ixR = xR - rim
        let izB = zB + rim, izF = zF - rim
        // Lower shell, set back under the upper shell's overhang.
        let lxL = xL + lip, lxR = xR - lip
        let lzB = zB + lip, lzF = zF - lip
        // Key well, inset by the same bezel as the 2D art.
        let dxL = xL + inSide, dxR = xR - inSide
        let dzB = zB + inBack, dzF = zF - inFront

        func topY(_ z: CGFloat) -> CGFloat {
            shift + frontH + (backH - frontH) * (zF - z) / d
        }
        func p(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 {
            SCNVector3(x, y, z)
        }
        let ySeam = yRim + (topY(zF) - yRim) * hull.seamFraction
        func uv(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        // The shell has no texture, so any UV mapping works.
        let plain = [uv(0, 1), uv(1, 1), uv(1, 0), uv(0, 0)]

        let tFL = p(xL, topY(zF), zF), tFR = p(xR, topY(zF), zF)
        let tBR = p(xR, topY(zB), zB), tBL = p(xL, topY(zB), zB)
        // Inner rectangle at rim level (r) and at platform level (c).
        let rFL = p(ixL, yRim, izF), rFR = p(ixR, yRim, izF)
        let rBR = p(ixR, yRim, izB), rBL = p(ixL, yRim, izB)
        let cFL = p(ixL, yPlatform, izF), cFR = p(ixR, yPlatform, izF)
        let cBR = p(ixR, yPlatform, izB), cBL = p(ixL, yPlatform, izB)

        // Crop the underside drawing to the platform instead of squeezing it,
        // so the feet stay round.
        let uMin = rim / w, uMax = 1 - rim / w
        let vMin = rim / d, vMax = 1 - rim / d

        // The top drawing covers the whole footprint, so each top quad takes UVs
        // from its own spot and the art lines up across the step. v is 0 at the
        // back, where the art's top row is. Measuring from the front flips the art.
        func topUV(_ x: CGFloat, _ z: CGFloat) -> CGPoint {
            CGPoint(x: (x - xL) / w, y: (z - zB) / d)
        }
        func topQuad(_ q: [SCNVector3]) -> (corners: [SCNVector3], uv: [CGPoint]) {
            (q, q.map { topUV($0.x, $0.z) })
        }
        // Bezel inner edge (e) and the well floor below it (f).
        let eFL = p(dxL, topY(dzF), dzF), eFR = p(dxR, topY(dzF), dzF)
        let eBR = p(dxR, topY(dzB), dzB), eBL = p(dxL, topY(dzB), dzB)
        let fFL = p(dxL, topY(dzF) - well, dzF), fFR = p(dxR, topY(dzF) - well, dzF)
        let fBR = p(dxR, topY(dzB) - well, dzB), fBL = p(dxL, topY(dzB) - well, dzB)

        // Corners run counter-clockwise as seen from outside, which SceneKit
        // treats as front-facing.
        let top: [(corners: [SCNVector3], uv: [CGPoint])] = [
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
        // Upper back wall with the sockets, from the seam up to the top.
        let back: [(corners: [SCNVector3], uv: [CGPoint])] = [
            ([p(xR, ySeam, zB), p(xL, ySeam, zB), tBL, tBR],
             [uv(0, 1), uv(1, 1), uv(1, 0), uv(0, 0)]),
        ]
        // Well walls, facing inward so they show from above.
        let seam: [(corners: [SCNVector3], uv: [CGPoint])] = [
            ([fFL, fBL, eBL, eFL], plain),
            ([fBR, fFR, eFR, eBR], plain),
            ([fFR, fFL, eFL, eFR], plain),
            ([fBL, fBR, eBR, eBL], plain),
        ]
        let shell: [(corners: [SCNVector3], uv: [CGPoint])] = [
            // Upper shell walls, from the seam up to the top.
            ([p(xL, ySeam, zF), p(xR, ySeam, zF), tFR, tFL], plain),   // front
            ([p(xL, ySeam, zB), p(xL, ySeam, zF), tFL, tBL], plain),   // left
            ([p(xR, ySeam, zF), p(xR, ySeam, zB), tBR, tFR], plain),   // right

            // Underside of the overhang, facing the desk.
            ([p(xL, ySeam, zF), p(xL, ySeam, lzF),
              p(xR, ySeam, lzF), p(xR, ySeam, zF)], plain),
            ([p(xL, ySeam, lzB), p(xL, ySeam, zB),
              p(xR, ySeam, zB), p(xR, ySeam, lzB)], plain),
            ([p(xL, ySeam, lzF), p(xL, ySeam, lzB),
              p(lxL, ySeam, lzB), p(lxL, ySeam, lzF)], plain),
            ([p(lxR, ySeam, lzF), p(lxR, ySeam, lzB),
              p(xR, ySeam, lzB), p(xR, ySeam, lzF)], plain),

            // Lower shell walls, from the rim up to the seam.
            ([p(lxL, yRim, lzF), p(lxR, yRim, lzF),
              p(lxR, ySeam, lzF), p(lxL, ySeam, lzF)], plain),
            ([p(lxR, yRim, lzB), p(lxL, yRim, lzB),
              p(lxL, ySeam, lzB), p(lxR, ySeam, lzB)], plain),
            ([p(lxL, yRim, lzB), p(lxL, yRim, lzF),
              p(lxL, ySeam, lzF), p(lxL, ySeam, lzB)], plain),
            ([p(lxR, yRim, lzF), p(lxR, yRim, lzB),
              p(lxR, ySeam, lzB), p(lxR, ySeam, lzF)], plain),

            // The level rim, from the lower shell in to the platform.
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

    /// Normal of the quad's first triangle.
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
