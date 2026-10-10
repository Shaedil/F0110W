import AppKit

enum HUDEntrance: String, CaseIterable {
    /// In from the right, fading up.
    case slide
    /// Down from under the menu bar, fading up.
    case drop
    case fade
}

/// How one state animates, so states can be told apart by motion as well as text.
struct HUDStyle: Equatable {
    var entrance: HUDEntrance
    var motion: BoardMotion
    var treatment: BoardTreatment

    static let defaults: [HUDKind: HUDStyle] = [
        // Arriving forms the board and leaving blows it away.
        .arrived: HUDStyle(entrance: .slide, motion: .assemble, treatment: .normal),
        .connected: HUDStyle(entrance: .slide, motion: .rock, treatment: .normal),
        // Still, so the battery ring draws the eye. The glyph stays normal because macOS only
        // turns the ring red, never the device icon.
        .lowBattery: HUDStyle(entrance: .slide, motion: .still, treatment: .normal),
        .disconnected: HUDStyle(entrance: .slide, motion: .dust, treatment: .normal),
        .died: HUDStyle(entrance: .slide, motion: .dust, treatment: .dim),
        // Still, since the keyboard is fine and the button is what matters.
        .movedAway: HUDStyle(entrance: .slide, motion: .still, treatment: .normal),
        .movedBack: HUDStyle(entrance: .slide, motion: .rock, treatment: .normal),
    ]
}

/// Board glyph on the left, name over status in the middle, battery ring on the right.
final class HUDView: NSView {
    private let metrics: HUDMetrics
    private let glyph = SpinningBoardView()
    private let titleLabel: NSTextField
    private let statusLabel: NSTextField
    private let ring: RingGauge
    private var ringWidth: NSLayoutConstraint!
    private lazy var moveBackButton = CircleIconButton(symbol: "arrow.uturn.backward",
                                                       label: "Move back to this computer",
                                                       diameter: metrics.ringDiameter,
                                                       pointSize: metrics.statusSize)
    var onMoveBack: (() -> Void)?

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

        moveBackButton.target = self
        moveBackButton.action = #selector(moveBack)
        moveBackButton.isHidden = true

        // Right slot: the battery ring, or the move-back button on a moved-away HUD. Hidden
        // views drop out of the stack and take no width.
        let accessory = NSStackView(views: [ring, moveBackButton])
        accessory.orientation = .horizontal
        accessory.spacing = metrics.gap
        accessory.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyph)
        addSubview(textStack)
        addSubview(accessory)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: metrics.height),

            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.padLeading),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: metrics.glyphWidth),
            glyph.heightAnchor.constraint(equalToConstant: metrics.glyphHeight),

            textStack.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: metrics.gap),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            accessory.leadingAnchor.constraint(equalTo: textStack.trailingAnchor, constant: metrics.gap),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.padTrailing),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            ringWidth,
            ring.heightAnchor.constraint(equalToConstant: metrics.ringDiameter),
        ])
    }

    @objc private func moveBack() { onMoveBack?() }

    /// `canMoveBack` shows the move-back button, which needs a way to reach the keyboard.
    func configure(kind: HUDKind, name: String, battery: Int?, lowThreshold: Int,
                   detail: String? = nil, canMoveBack: Bool = false) {
        titleLabel.stringValue = name

        statusLabel.stringValue = kind.status(detail: detail)

        moveBackButton.isHidden = !(kind == .movedAway && canMoveBack)

        // No ring on a disconnect (stale level) or a moved-away HUD (the button goes there).
        let showRing = battery != nil && kind.showsRing
        ring.isHidden = !showRing
        ringWidth.constant = showRing ? metrics.ringDiameter : 0

        if let battery, showRing {
            ring.isLow = battery <= lowThreshold
            ring.level = battery
        }

        needsLayout = true
    }

    func setSpinning(_ spinning: Bool) { glyph.setSpinning(spinning) }

    /// Updates the board's fade for a new battery level without restarting its motion.
    func dimBoard(_ style: HUDStyle, battery: Int?) {
        glyph.setTreatment(style.treatment, battery: battery)
    }

    /// `hold` is how long the HUD stays up. A crumble times its end to it.
    func animateBoard(_ style: HUDStyle, battery: Int?, reduced: Bool, hold: TimeInterval? = nil) {
        glyph.setTreatment(style.treatment, battery: battery)
        glyph.play(style.motion, reduced: reduced, hold: hold)
    }

    /// Frames of the laid-out parts, for checking geometry.
    func geometryReport() -> String {
        layoutSubtreeIfNeeded()
        return String(format: "view=%.1fx%.1f glyph=[%.1f..%.1f] text=[%.1f..%.1f] ring=[%.1f..%.1f] trailingGap=%.1f",
                      bounds.width, bounds.height,
                      glyph.frame.minX, glyph.frame.maxX,
                      titleLabel.superview?.frame.minX ?? -1, titleLabel.superview?.frame.maxX ?? -1,
                      ring.frame.minX, ring.frame.maxX,
                      bounds.maxX - ring.frame.maxX)
    }

    /// Width that fits the text, clamped to `minWidth...maxWidth`.
    var preferredSize: NSSize {
        layoutSubtreeIfNeeded()
        let natural = fittingSize.width
        return NSSize(width: min(max(natural, metrics.minWidth), metrics.maxWidth),
                      height: metrics.height)
    }
}

/// Round icon button the size of the battery ring, like the AirPods "moved to" HUD. It takes
/// the first click because the HUD panel is never key, so a normal button would ignore it.
final class CircleIconButton: NSButton {
    private let diameter: CGFloat

    init(symbol: String, label: String, diameter: CGFloat, pointSize: CGFloat) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .labelColor
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isHighlighted: Bool {
        didSet { paintDisc() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintDisc()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paintDisc()
    }

    /// Resolved per appearance so it follows a light/dark switch. Set on the layer because
    /// draw(_:) belongs to the button cell.
    private func paintDisc() {
        guard let layer else { return }
        layer.cornerRadius = diameter / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = isHighlighted ? .tertiaryLabelColor : .quaternaryLabelColor
            layer.backgroundColor = fill.cgColor
        }
    }
}
