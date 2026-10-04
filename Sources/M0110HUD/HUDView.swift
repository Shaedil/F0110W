import AppKit

/// What a HUD is announcing.
enum HUDKind: String, CaseIterable {
    /// The first connect of the day: after hours away, or on a new day.
    case arrived
    /// Any other connect.
    case connected
    case lowBattery
    case disconnected
    /// Gone with a flat battery: a report of 0%, or a disconnect right after
    /// a near-empty one.
    case died
    /// The keyboard switched to another of its Bluetooth profiles.
    case movedAway
    /// The keyboard switched back to this computer from another profile.
    case movedBack

    /// Whether the battery ring belongs on this HUD when a level is known.
    var showsRing: Bool {
        switch self {
        case .arrived, .connected, .lowBattery, .movedBack: true
        case .disconnected, .died, .movedAway: false
        }
    }
}

/// Profile names the user has given in Settings, for "Moved to ...".
enum ProfileNames {
    static let count = 5

    static func key(_ index: Int) -> String { "profileName\(index)" }

    /// The name for a 0-based profile index, or "Profile N" when none is set.
    static func name(for index: Int, in defaults: UserDefaults = .standard) -> String {
        if let n = defaults.string(forKey: key(index))?.trimmingCharacters(in: .whitespaces),
           !n.isEmpty {
            return n
        }
        return "Profile \(index + 1)"
    }
}

/// How the HUD arrives.
enum HUDEntrance: String, CaseIterable {
    /// In from the right, fading up.
    case slide
    /// Down from under the menu bar, fading up.
    case drop
    /// Fade up in place.
    case fade
}

/// How one state animates, so the states can be told apart by motion and not
/// only by reading the status line.
struct HUDStyle: Equatable {
    var entrance: HUDEntrance
    var motion: BoardMotion
    var treatment: BoardTreatment

    static let defaults: [HUDKind: HUDStyle] = [
        // Arriving for the day and leaving are the snap, forwards and
        // backwards: the board forms, or it blows away.
        .arrived: HUDStyle(entrance: .slide, motion: .assemble, treatment: .normal),
        .connected: HUDStyle(entrance: .slide, motion: .rock, treatment: .normal),
        // Still, so the battery ring is what moves the eye. The product glyph
        // keeps its normal treatment; macOS only reddens the ring, never the
        // device icon.
        .lowBattery: HUDStyle(entrance: .slide, motion: .still, treatment: .normal),
        .disconnected: HUDStyle(entrance: .slide, motion: .dust, treatment: .normal),
        .died: HUDStyle(entrance: .slide, motion: .dust, treatment: .dim),
        // Still: the keyboard is fine, just busy elsewhere, and the button is
        // what matters.
        .movedAway: HUDStyle(entrance: .slide, motion: .still, treatment: .normal),
        .movedBack: HUDStyle(entrance: .slide, motion: .rock, treatment: .normal),
    ]
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
    private lazy var moveBackButton = CircleIconButton(symbol: "arrow.uturn.backward",
                                                       label: "Move back to this computer",
                                                       diameter: metrics.ringDiameter,
                                                       pointSize: metrics.statusSize)
    /// Called when "Move back" is clicked on a moved-away HUD.
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

        // The right-hand slot: the battery ring, or on a moved-away HUD the
        // button that brings the keyboard back. Hidden views drop out of the
        // stack, so an empty slot takes no width.
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

    /// `detail` is the profile name on a moved-away HUD. `canMoveBack` shows
    /// the button, which needs a way to reach the keyboard.
    func configure(kind: HUDKind, name: String, battery: Int?, lowThreshold: Int,
                   detail: String? = nil, canMoveBack: Bool = false) {
        titleLabel.stringValue = name

        switch kind {
        case .arrived, .connected: statusLabel.stringValue = "Connected"
        case .disconnected:        statusLabel.stringValue = "Disconnected"
        case .lowBattery:          statusLabel.stringValue = "Low Battery"
        case .died:                statusLabel.stringValue = "Battery Empty"
        case .movedAway:           statusLabel.stringValue = "Moved to \(detail ?? "another device")"
        case .movedBack:           statusLabel.stringValue = "Moved back"
        }

        moveBackButton.isHidden = !(kind == .movedAway && canMoveBack)

        // On a disconnect the level is stale, and a moved-away HUD has the
        // button there instead, so the ring collapses away entirely.
        let showRing = battery != nil && kind.showsRing
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

    /// Put the board into a state's motion and treatment.
    /// Refade the board for a new battery level without restarting its motion.
    func dimBoard(_ style: HUDStyle, battery: Int?) {
        glyph.setTreatment(style.treatment, battery: battery)
    }

    func animateBoard(_ style: HUDStyle, battery: Int?, reduced: Bool) {
        glyph.setTreatment(style.treatment, battery: battery)
        glyph.play(style.motion, reduced: reduced)
    }

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

/// A round icon button the size of the battery ring, which it stands in for:
/// the AirPods "moved to" HUD's shape, a symbol on a soft disc.
///
/// It answers the first click in a window that is not key, which the HUD
/// never is: it is a non-activating panel, and a plain button there would
/// spend the click making the window key instead of pressing.
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

    /// The disc behind the symbol, resolved per appearance so it follows a
    /// light/dark switch: a faint fill at rest, a stronger one while pressed.
    /// On the layer rather than in draw(_:), which is the button cell's.
    private func paintDisc() {
        guard let layer else { return }
        layer.cornerRadius = diameter / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = isHighlighted ? .tertiaryLabelColor : .quaternaryLabelColor
            layer.backgroundColor = fill.cgColor
        }
    }
}
