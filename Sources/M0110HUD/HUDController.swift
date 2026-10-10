import AppKit

/// Opaque fill that replaces the blur as transparency goes down. It draws instead of using a
/// layer background color so `windowBackgroundColor` re-resolves on a light/dark switch.
private final class HUDBacking: NSView {
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// Owns the panel. Showing it again while visible updates it in place and restarts the hold timer.
final class HUDController {
    private var panel: NSPanel?
    private var view: HUDView?
    private var backing: HUDBacking?
    private var effect: NSVisualEffectView?
    private var dismissWork: DispatchWorkItem?
    /// Bumped on every show so a stale fade completion cannot hide a newer HUD.
    private var fadeGeneration = 0
    private let duration: TimeInterval
    private let lowThreshold: Int
    private let metrics: HUDMetrics
    private let forcedAppearance: NSAppearance?
    private let materialName: String
    private let transparency: SystemTransparency

    private var slideOffset: CGFloat { 26 * metrics.scale }

    /// Strong expo ease-out. The built-in `.easeOut` feels too slow.
    private static let arrive = CAMediaTimingFunction(controlPoints: 0.19, 1, 0.22, 1)
    /// Leaving is a fade in place, like Apple's HUDs, using the CSS `ease` curve.
    private static let leave = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    static let fadeOut: TimeInterval = 0.5

    /// Overrides Reduce Motion for the debug panel. Nil follows System Settings.
    var forceReduceMotion: Bool?

    private var reduceMotion: Bool {
        forceReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func offset(_ frame: NSRect, for entrance: HUDEntrance, by distance: CGFloat) -> NSRect {
        var f = frame
        switch entrance {
        case .slide: f.origin.x += distance
        case .drop:  f.origin.y += distance
        case .fade:  break
        }
        return f
    }

    /// Keeps the HUD up for the debug panel. Unpinning a visible HUD starts the normal hold timer.
    var pinned = false {
        didSet {
            guard pinned != oldValue else { return }
            if pinned {
                dismissWork?.cancel()
            } else if let panel, panel.isVisible, panel.alphaValue > 0.01 {
                scheduleDismiss()
            }
        }
    }

    var styles = HUDStyle.defaults

    /// Called for each `show`, so the debug panel can log the HUDs produced.
    var onShow: ((HUDKind, String, Int?) -> Void)?

    /// The moved-away HUD shows its move-back button only when this is set.
    var onMoveBack: (() -> Void)?

    /// Lets a late battery reading update the visible HUD without changing its text.
    private var current: (kind: HUDKind, detail: String?)?

    init(duration: TimeInterval,
         lowThreshold: Int,
         metrics: HUDMetrics,
         appearance: String? = nil,
         material: String = "toolTip",
         transparency: SystemTransparency) {
        self.duration = duration
        self.lowThreshold = lowThreshold
        self.metrics = metrics
        self.materialName = material
        self.transparency = transparency
        switch appearance {
        case "light": self.forcedAppearance = NSAppearance(named: .vibrantLight)
        case "dark":  self.forcedAppearance = NSAppearance(named: .vibrantDark)
        default:      self.forcedAppearance = nil
        }
        // Restyle a visible HUD right away when "Reduce transparency" changes.
        transparency.onChange = { [weak self] level in self?.apply(level: level) }
    }

    /// The vibrancy view stays at every level and only the opaque fill on top changes. At 0 the
    /// blur is also turned off, as Reduce transparency asks, which saves window server work.
    private func apply(level: Double) {
        backing?.alphaValue = CGFloat(1 - level)
        effect?.state = level <= 0.01 ? .inactive : .active
    }


    private static func material(named name: String) -> NSVisualEffectView.Material {
        switch name {
        case "hudWindow":            return .hudWindow
        case "menu":                 return .menu
        case "sidebar":              return .sidebar
        case "headerView":           return .headerView
        case "windowBackground":     return .windowBackground
        case "contentBackground":    return .contentBackground
        case "underWindowBackground":return .underWindowBackground
        case "fullScreenUI":         return .fullScreenUI
        case "toolTip":              return .toolTip
        case "titlebar":             return .titlebar
        case "selection":            return .selection
        case "sheet":                return .sheet
        case "popover":              return .popover
        default:                     return .toolTip
        }
    }

    /// Cap insets let one small image stretch to any HUD width without distorting the corners.
    private static func capsuleMask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge),
                            flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius,
                                       bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func makePanel() -> (NSPanel, HUDView) {
        let content = HUDView(metrics: metrics)

        let effect = NSVisualEffectView()
        effect.material = Self.material(named: materialName)
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = metrics.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        // A layer corner radius does not clip the behind-window blur, which the window server
        // draws for the full rectangle, so square corners show. Only maskImage shapes the blur
        // and the shadow.
        effect.maskImage = Self.capsuleMask(radius: metrics.cornerRadius)

        // Between the blur and the content, so lowering transparency hides only the blur.
        let fill = HUDBacking(radius: metrics.cornerRadius)
        fill.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(fill)

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            fill.topAnchor.constraint(equalTo: effect.topAnchor),
            fill.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        self.effect = effect
        self.backing = fill
        apply(level: transparency.level)

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: metrics.minWidth, height: metrics.height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.contentView = effect
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.alphaValue = 0
        p.appearance = forcedAppearance

        return (p, content)
    }

    func show(kind: HUDKind, name: String, battery: Int?, detail: String? = nil) {
        DebugLog.shared.add(.app, "showing \(kind)"
            + (detail.map { " (\($0))" } ?? "") + (battery.map { ", battery \($0)%" } ?? ""))
        // The accessibility notification catches changes while running. This catches a level
        // that changed since the panel was built, and costs almost nothing.
        transparency.refresh()

        if panel == nil {
            let (p, v) = makePanel()
            panel = p
            view = v
        }
        guard let panel, let view else { return }

        let canMoveBack = kind == .movedAway && onMoveBack != nil
        view.onMoveBack = { [weak self] in self?.onMoveBack?() }
        view.configure(kind: kind, name: name, battery: battery, lowThreshold: lowThreshold,
                       detail: detail, canMoveBack: canMoveBack)
        // Clicks pass through the HUD unless it has a button.
        panel.ignoresMouseEvents = !canMoveBack
        current = (kind, detail)
        let style = styles[kind] ?? HUDStyle.defaults[kind]!

        let size = view.preferredSize
        if ProcessInfo.processInfo.arguments.contains("--verbose") {
            print("[geom] \(view.geometryReport()) preferred=\(size.width)x\(size.height) radius=\(metrics.cornerRadius)")
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let target = NSRect(x: visible.maxX - size.width - metrics.insetX,
                            y: visible.maxY - size.height - metrics.insetY,
                            width: size.width,
                            height: size.height)

        let reduced = reduceMotion
        let onScreen = panel.isVisible && panel.alphaValue > 0.01

        if onScreen && panel.alphaValue > 0.99 {
            panel.setFrame(target, display: true, animate: false)
        } else if onScreen {
            // Caught mid-fade. Continue from where it is instead of restarting the entrance.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = Self.arrive
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            // Under Reduce Motion the panel only fades.
            let entrance: HUDEntrance = reduced ? .fade : style.entrance
            panel.setFrame(offset(target, for: entrance, by: slideOffset), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = entrance == .fade ? 0.3 : 0.4
                ctx.timingFunction = Self.arrive
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        }

        holdFor = Self.hold(for: style, configured: duration)
        view.setSpinning(true)
        view.animateBoard(style, battery: battery, reduced: reduced, hold: holdFor)
        scheduleDismiss()
        onShow?(kind, name, battery)
    }

    func dismissNow() {
        dismissWork?.cancel()
        dismiss()
    }

    /// Removes the panel at once, for a controller being replaced.
    func tearDown() {
        dismissWork?.cancel()
        fadeGeneration += 1
        view?.setSpinning(false)
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    /// For the BAS read that arrives just after connect. Does not restart the hold timer.
    func updateBatteryIfVisible(name: String, battery: Int) {
        guard let panel, let view, let current, panel.isVisible, panel.alphaValue > 0.01 else { return }
        view.configure(kind: current.kind, name: name, battery: battery, lowThreshold: lowThreshold,
                       detail: current.detail,
                       canMoveBack: current.kind == .movedAway && onMoveBack != nil)
        view.dimBoard(styles[current.kind] ?? HUDStyle.defaults[current.kind]!, battery: battery)
        var frame = panel.frame
        let size = view.preferredSize
        if ProcessInfo.processInfo.arguments.contains("--verbose") {
            print("[geom] \(view.geometryReport()) preferred=\(size.width)x\(size.height) radius=\(metrics.cornerRadius)")
        }
        // Keep the right edge pinned as the width changes.
        frame.origin.x = frame.maxX - size.width
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }

    private var holdFor: TimeInterval = 0

    /// The configured hold, but never shorter than the crumble. The crumble runs at the end of
    /// the hold, so the HUD fades right as the last dust goes. An empty capsule after the dust
    /// looks stuck, and fading earlier cuts off the crumble.
    static func hold(for style: HUDStyle, configured: TimeInterval) -> TimeInterval {
        guard style.motion == .dust else { return configured }
        return max(configured, SpinningBoardView.dustEnds)
    }

    private func scheduleDismiss() {
        dismissWork?.cancel()
        fadeGeneration += 1
        if pinned { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (holdFor > 0 ? holdFor : duration),
                                      execute: work)
    }

    private func dismiss() {
        guard let panel else { return }
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOut
            ctx.timingFunction = Self.leave
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Hide only if no new HUD arrived during the fade.
            guard let self, generation == self.fadeGeneration else { return }
            panel.orderOut(nil)
            self.view?.setSpinning(false)
        })
    }
}
