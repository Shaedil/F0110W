import SwiftUI

/// The M0110's back face, which carries the keyboard's sockets.
///
/// Drawn from the reference photograph: the wide recessed jack that the coiled
/// cable plugs into, the smaller square socket beside it, and the two moulded
/// icons that label them. Until this existed the front wall was bare plastic,
/// and a board with no port anywhere on it is the kind of wrong you notice
/// without being able to say why.
///
/// These are close to their real proportions, unlike the underside's fittings.
/// The back wall is the tall one, 45 mm against the front's 20 mm, so a socket
/// on it is big enough to read at HUD size without being inflated. They are
/// only darkened, so the openings hold up once the texture is downscaled.
struct BoardBackView: View {
    /// Points per unit-hundredth, the same convention `BoardArtView` uses.
    let scale: CGFloat
    /// Face size in unit-hundredths: the case width, and the wall's height.
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

            // Off to one side rather than centred. `u` runs left to right as
            // seen from behind the board, which is how the reference was shot,
            // so this is 78% across that view -- about a fifth in from the left
            // end when you are sitting at the keyboard.
            let clusterX = w * 0.78

            // The wide cable jack, drawn nearly the full height of the wall.
            // At true size it is a third of a point in the HUD; what matters
            // here is that a socket is visibly *there*.
            let jackW = w * 0.10, jackH = h * 0.34
            let jack = CGRect(x: clusterX - jackW / 2, y: h * 0.40,
                              width: jackW, height: jackH)
            context.fill(Path(roundedRect: jack, cornerRadius: h * 0.04),
                         with: .color(Theme.portRecess))
            context.fill(Path(roundedRect: jack.insetBy(dx: jackW * 0.09,
                                                        dy: jackH * 0.20),
                              cornerRadius: h * 0.03),
                         with: .color(Theme.portMouth))

            // The smaller square socket beside it.
            let sqSide = h * 0.28
            let square = CGRect(x: clusterX + jackW * 0.90, y: h * 0.42,
                                width: sqSide, height: sqSide)
            context.fill(Path(roundedRect: square, cornerRadius: h * 0.03),
                         with: .color(Theme.portRecess))
            context.fill(Path(roundedRect: square.insetBy(dx: sqSide * 0.24,
                                                          dy: sqSide * 0.24),
                              cornerRadius: h * 0.02),
                         with: .color(Theme.portMouth))

            // The moulded icons the reference has either side of the cluster
            // are left out: at this size they are two grey specks that read as
            // dirt on the case rather than as symbols.
        }
        .frame(width: box.width, height: box.height)
    }
}
