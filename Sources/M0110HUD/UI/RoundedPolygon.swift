import SwiftUI

/// A closed polygon with every corner rounded, convex and concave alike.
///
/// `addArc(tangent1End:tangent2End:radius:)` inscribes an arc tangent to the two
/// segments meeting at a corner, and does the right thing at a reflex corner as
/// well. That is what makes this usable for the two shapes in the drawing that
/// are not rectangles: the plate, which has a notch bitten out of each bottom
/// corner, and the ISO Return, which is an L.
///
/// Points are supplied by a closure taking the rect the shape is drawn into, so
/// a caller can define its outline relative to the size it is handed, or ignore
/// the rect and use absolute coordinates, as the plate does.
struct RoundedPolygon: Shape {
    var radius: CGFloat
    var points: @Sendable (CGRect) -> [CGPoint]

    init(radius: CGFloat, points: @escaping @Sendable (CGRect) -> [CGPoint]) {
        self.radius = radius
        self.points = points
    }

    init(radius: CGFloat, points: [CGPoint]) {
        self.radius = radius
        self.points = { _ in points }
    }

    func path(in rect: CGRect) -> Path {
        let corners = points(rect)
        var path = Path()
        guard corners.count >= 3 else { return path }
        // Start mid-edge, so the first corner is an arc like all the others
        // rather than a hard start point.
        path.move(to: midpoint(corners[corners.count - 1], corners[0]))
        for i in corners.indices {
            path.addArc(tangent1End: corners[i],
                        tangent2End: corners[(i + 1) % corners.count],
                        radius: radius)
        }
        path.closeSubpath()
        return path
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
