import AppKit

enum HUDKind {
    case connected
    case disconnected
    case lowBattery
}

/// The HUD's content: product glyph on the left, centered name over status in the
/// middle, battery ring on the right.
final class HUDView: NSView {
    private let metrics: HUDMetrics
    private let glyph = SpinningBoardView()
    private let titleLabel: NSTextField
    private let statusLabel: NSTextField
    private let ring: RingGauge
    private var ringWidth: NSLayoutConstraint!

    init(metrics: HUDMetrics) {
        self.metrics = metrics
        self.titleLabel = Self.makeLabel(size: metrics.titleSize, weight: .bold, color: .labelColor)
        self.statusLabel = Self.makeLabel(size: metrics.statusSize, weight: .regular, color: .secondaryLabelColor)
        self.ring = RingGauge(metrics: metrics)
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    private func build() {
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, statusLabel])
        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false

        ring.translatesAutoresizingMaskIntoConstraints = false
        ringWidth = ring.widthAnchor.constraint(equalToConstant: metrics.ringDiameter)

        addSubview(glyph)
        addSubview(textStack)
        addSubview(ring)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: metrics.height),

            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.padLeading),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: metrics.glyphWidth),
            glyph.heightAnchor.constraint(equalToConstant: metrics.glyphHeight),

            textStack.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: metrics.gap),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            ring.leadingAnchor.constraint(equalTo: textStack.trailingAnchor, constant: metrics.gap),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.padTrailing),
            ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ringWidth,
            ring.heightAnchor.constraint(equalToConstant: metrics.ringDiameter),
        ])
    }

    func configure(kind: HUDKind, name: String, battery: Int?, lowThreshold: Int) {
        titleLabel.stringValue = name

        switch kind {
        case .connected:
            statusLabel.stringValue = "Connected"
            glyph.isDimmed = false
        case .disconnected:
            statusLabel.stringValue = "Disconnected"
            glyph.isDimmed = true
        case .lowBattery:
            statusLabel.stringValue = "Low Battery"
            // The product glyph keeps its normal treatment; macOS only reddens
            // the battery ring, never the device icon.
            glyph.isDimmed = false
        }

        // On disconnect the level is stale, so collapse the ring away entirely.
        let showRing = battery != nil && kind != .disconnected
        ring.isHidden = !showRing
        ringWidth.constant = showRing ? metrics.ringDiameter : 0

        if let battery, showRing {
            ring.isLow = battery <= lowThreshold
            ring.level = battery
        }

        needsLayout = true
    }

    /// Run the board's animation only while the HUD is actually on screen.
    func setSpinning(_ spinning: Bool) { glyph.setSpinning(spinning) }

    /// Frames of the laid-out parts, for verifying geometry against a reference.
    func geometryReport() -> String {
        layoutSubtreeIfNeeded()
        return String(format: "view=%.1fx%.1f glyph=[%.1f..%.1f] text=[%.1f..%.1f] ring=[%.1f..%.1f] trailingGap=%.1f",
                      bounds.width, bounds.height,
                      glyph.frame.minX, glyph.frame.maxX,
                      titleLabel.superview?.frame.minX ?? -1, titleLabel.superview?.frame.maxX ?? -1,
                      ring.frame.minX, ring.frame.maxX,
                      bounds.maxX - ring.frame.maxX)
    }

    /// Width that fits the current text, clamped to a HUD-like range.
    var preferredSize: NSSize {
        layoutSubtreeIfNeeded()
        let natural = fittingSize.width
        return NSSize(width: min(max(natural, metrics.minWidth), metrics.maxWidth),
                      height: metrics.height)
    }
}
