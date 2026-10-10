import SwiftUI

/// The M0110's back face, with the cable jack and the square socket next to it.
struct BoardBackView: View {
    /// Points per hundredth of a key unit.
    let scale: CGFloat
    /// Case width and wall height, in hundredths of a key unit.
    let span: CGSize

    static func size(span: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: span.width * scale, height: span.height * scale)
    }

    var body: some View {
        let box = Self.size(span: span, scale: scale)
        Canvas { context, _ in
            let w = box.width, h = box.height

            context.fill(Path(CGRect(origin: .zero, size: box)),
                         with: .color(Theme.caseFlat))

            // x runs left to right as seen from behind, so 0.78 is about a fifth
            // in from the left end as seen by the person typing.
            let clusterX = w * 0.78

            // Cable jack, drawn larger than real so it is visible at HUD size.
            let jackW = w * 0.10, jackH = h * 0.34
            let jack = CGRect(x: clusterX - jackW / 2, y: h * 0.40,
                              width: jackW, height: jackH)
            context.fill(Path(roundedRect: jack, cornerRadius: h * 0.04),
                         with: .color(Theme.portRecess))
            context.fill(Path(roundedRect: jack.insetBy(dx: jackW * 0.09,
                                                        dy: jackH * 0.20),
                              cornerRadius: h * 0.03),
                         with: .color(Theme.portMouth))

            let sqSide = h * 0.28
            let square = CGRect(x: clusterX + jackW * 0.90, y: h * 0.42,
                                width: sqSide, height: sqSide)
            context.fill(Path(roundedRect: square, cornerRadius: h * 0.03),
                         with: .color(Theme.portRecess))
            context.fill(Path(roundedRect: square.insetBy(dx: sqSide * 0.24,
                                                          dy: sqSide * 0.24),
                              cornerRadius: h * 0.02),
                         with: .color(Theme.portMouth))

            // The moulded icons next to the sockets are left out. At this size
            // they look like dirt on the case.
        }
        .frame(width: box.width, height: box.height)
    }
}
