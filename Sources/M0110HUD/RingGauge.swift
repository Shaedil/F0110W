import AppKit

/// Battery ring with the level inside, like the gauge in macOS accessory popups: a faint
/// full track under a colored arc that runs clockwise from 12 o'clock.
final class RingGauge: NSView {
    var level: Int? {
        didSet {
            label.stringValue = level.map(String.init) ?? ""
            needsDisplay = true
        }
    }

    /// Only the arc color changes. The number and glyph stay neutral, as in macOS.
    var isLow = false {
        didSet { needsDisplay = true }
    }

    private let metrics: HUDMetrics
    private let label: NSTextField

    init(metrics: HUDMetrics) {
        self.metrics = metrics
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: metrics.ringFontSize, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        self.label = l

        super.init(frame: .zero)
        addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: centerXAnchor),
            l.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: metrics.ringDiameter, height: metrics.ringDiameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lw = metrics.ringLineWidth
        let rect = bounds.insetBy(dx: lw / 2 + 0.5, dy: lw / 2 + 0.5)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        guard radius > 0 else { return }

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lw
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.stroke()

        guard let level, level > 0 else { return }
        let fraction = CGFloat(min(max(level, 0), 100)) / 100

        // AppKit angles run counterclockwise from 3 o'clock, so start at 90 degrees and go
        // clockwise to begin at the top.
        let start: CGFloat = 90
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center,
                      radius: radius,
                      startAngle: start,
                      endAngle: start - 360 * fraction,
                      clockwise: true)
        arc.lineWidth = lw
        arc.lineCapStyle = .round
        (isLow ? NSColor.systemRed : NSColor.systemGreen).setStroke()
        arc.stroke()
    }
}
