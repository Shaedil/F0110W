import SwiftUI

/// A closed polygon with every corner rounded, convex and concave alike.
/// `addArc(tangent1End:tangent2End:radius:)` handles reflex corners too, which
/// the plate's notches and the ISO Return's L need.
///
/// The points closure gets the drawing rect, which callers may ignore.
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
        // Start mid-edge so the first corner gets an arc too.
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
