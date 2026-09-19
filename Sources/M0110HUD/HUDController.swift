import AppKit

/// Owns the borderless panel: slides it in at the top-right of the active
/// screen, holds it, then fades it out. Re-showing while visible updates the
/// content in place and restarts the hold timer.
final class HUDController {
    private var panel: NSPanel?
    private var view: HUDView?
    private var dismissWork: DispatchWorkItem?
    /// Bumped on every show so a stale fade completion can't hide a newer HUD.
    private var fadeGeneration = 0
    private let duration: TimeInterval
    private let lowThreshold: Int
    private let metrics: HUDMetrics
    private let forcedAppearance: NSAppearance?
    private let materialName: String

    private var slideOffset: CGFloat { 26 * metrics.scale }

    init(duration: TimeInterval,
         lowThreshold: Int,
         metrics: HUDMetrics,
         appearance: String? = nil,
         material: String = "toolTip") {
        self.duration = duration
        self.lowThreshold = lowThreshold
        self.metrics = metrics
        self.materialName = material
        switch appearance {
        case "light": self.forcedAppearance = NSAppearance(named: .vibrantLight)
        case "dark":  self.forcedAppearance = NSAppearance(named: .vibrantDark)
        // nil leaves the panel following the system, which is the default.
        default:      self.forcedAppearance = nil
        }
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

    /// Resizable rounded-rect mask for the vibrancy view. Cap insets let one
    /// small image stretch to any HUD width without distorting the corners.
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
        // A layer corner radius clips the view's own drawing but NOT the
        // behind-window blur, which the window server renders for the full
        // rectangular frame, which leaks visible square corners. maskImage is
        // the only thing that shapes the vibrancy itself (and the shadow).
        effect.maskImage = Self.capsuleMask(radius: metrics.cornerRadius)

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

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

    func show(kind: HUDKind, name: String, battery: Int?) {
        if panel == nil {
            let (p, v) = makePanel()
            panel = p
            view = v
        }
        guard let panel, let view else { return }

        view.configure(kind: kind, name: name, battery: battery, lowThreshold: lowThreshold)

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

        // Only treat it as "already up" when it is fully opaque; mid-fade we must
        // cancel the fade and bring the alpha back, or it will vanish under us.
        let wasVisible = panel.isVisible && panel.alphaValue > 0.99

        if wasVisible {
            // Already on screen: just resize/reposition, no slide.
            panel.setFrame(target, display: true, animate: false)
        } else {
            var start = target
            start.origin.x += slideOffset
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        }

        view.setSpinning(true)
        scheduleDismiss()
    }

    /// Update the battery on an already-visible HUD (the BAS read lands a moment
    /// after the connect event) without restarting the hold timer.
    func updateBatteryIfVisible(kind: HUDKind, name: String, battery: Int) {
        guard let panel, let view, panel.isVisible, panel.alphaValue > 0.01 else { return }
        view.configure(kind: kind, name: name, battery: battery, lowThreshold: lowThreshold)
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

    private func scheduleDismiss() {
        dismissWork?.cancel()
        fadeGeneration += 1
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func dismiss() {
        guard let panel else { return }
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new HUD may have arrived mid-fade; only hide if none did.
            guard let self, generation == self.fadeGeneration else { return }
            panel.orderOut(nil)
            self.view?.setSpinning(false)
        })
    }
}
