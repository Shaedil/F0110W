import Foundation

/// The two plate measurements M0110Layout takes from the Mac's BoardCase, a
/// SwiftUI view that does not build here.
enum BoardCase {
    static let keyGap: CGFloat = 7
    static var plateInset: CGFloat { keyGap / 2 }
}
