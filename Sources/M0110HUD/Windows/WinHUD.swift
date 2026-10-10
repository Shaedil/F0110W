import CM0110Win
import Foundation

/// A layered window by the tray that slides in, holds and fades out. Showing it
/// while it is up updates it in place and restarts the hold.
final class WinHUD {
    var config: Config
    private let text = GDIText()

    private var content: HUDContent?
    private var rest = (x: 0, y: 0)
    private var towardsEdge: Float = 1
    private var shown = false
    private var alpha: Float = 0
    /// Distance from `rest`, toward the screen edge.
    private var offset: Float = 0
    private var scale: Float = 1

    private struct Animation {
        var start: Double
        var duration: Double
        var from: (alpha: Float, offset: Float)
        var to: (alpha: Float, offset: Float)
        var curve: (Float) -> Float
        var done: (() -> Void)?
    }

    private var animation: Animation?
    private var frameTimer: UInt32?
    private var holdTimer: UInt32?

    /// Same as the Mac: a steep ease-out coming in, a plain ease going out.
    private static let enter = 0.35
    private static let leave = 0.5
    private static func expoOut(_ t: Float) -> Float { t >= 1 ? 1 : 1 - pow(2, -10 * t) }
    private static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    init(config: Config) {
        self.config = config
    }

    var isVisible: Bool { shown && alpha > 0.01 }

    private var theme: HUDTheme {
        // Match the system flyouts, which follow the taskbar theme.
        let dark: Bool
        switch config.appearance {
        case "dark": dark = true
        case "light": dark = false
        default: dark = m0110_taskbar_dark() != 0
        }
        return HUDTheme(dark: dark, translucent: m0110_transparency() != 0)
    }

    func show(kind: HUDKind, name: String, battery: Int?, detail: String? = nil) {
        let wasVisible = isVisible
        present(HUDContent(kind: kind, name: name, battery: battery, detail: detail,
                           lowThreshold: config.lowThreshold))
        let reduced = m0110_reduce_motion() != 0
        if !wasVisible {
            alpha = 0
            offset = reduced ? 0 : 26 * scale
            apply()
            animate(to: (1, 0), duration: reduced ? 0.2 : Self.enter, curve: Self.expoOut)
        } else if alpha < 0.99 || animation != nil {
            // It was fading out, so fade back in instead of starting over.
            animate(to: (1, 0), duration: 0.2, curve: Self.ease)
        }
        Main.cancel(holdTimer)
        holdTimer = Main.after(config.hudDuration) { [weak self] in self?.dismiss() }
        log("hud: \(kind.rawValue) \(name) \(battery.map { "\($0)%" } ?? "-")", verbose: config.verbose)
    }

    func updateBatteryIfVisible(name: String, battery: Int) {
        guard isVisible, var content else { return }
        content.name = name
        content.battery = battery
        present(content)
    }

    func dismiss() {
        Main.cancel(holdTimer)
        holdTimer = nil
        guard shown else { return }
        animate(to: (0, 0), duration: Self.leave, curve: Self.ease) { [weak self] in
            m0110_hud_hide()
            self?.shown = false
        }
    }

    /// Redraws for the current screen without resetting the animation.
    private func present(_ content: HUDContent) {
        self.content = content
        let screen = m0110_current_screen()
        scale = Float(screen.dpi) / 96 * Float(config.scale)
        let image = HUDArt.render(content, metrics: WinHUDMetrics(scale: scale), theme: theme, text: text)

        // The corner by the tray, inset by the Settings values (pixels at 96 DPI).
        let dpi = Float(screen.dpi) / 96
        let side = Int((Float(config.insetX) * dpi).rounded())
        let gap = Int((Float(config.insetY) * dpi).rounded())
        let capsule = image.capsule
        let work = screen.work
        let right = screen.taskbar_edge != 0
        let top = screen.taskbar_edge == 1
        rest.x = right ? Int(work.right) - side - capsule.width - capsule.x : Int(work.left) + side - capsule.x
        rest.y = top ? Int(work.top) + gap - capsule.y : Int(work.bottom) - gap - capsule.height - capsule.y
        towardsEdge = right ? 1 : -1

        let pixels = image.canvas.bgraPremultiplied()
        let status = m0110_hud_present(pixels, Int32(image.canvas.width), Int32(image.canvas.height),
                                       Int32(position.x), Int32(position.y), byte(alpha))
        if status != 0 { log("hud: could not draw (\(status))", verbose: config.verbose) }
        shown = status == 0
    }

    private var position: (x: Int, y: Int) {
        (rest.x + Int((offset * towardsEdge).rounded()), rest.y)
    }

    private func byte(_ value: Float) -> UInt8 { UInt8(min(max(value, 0), 1) * 255 + 0.5) }

    private func apply() {
        m0110_hud_move(Int32(position.x), Int32(position.y), byte(alpha))
    }

    private func animate(to target: (alpha: Float, offset: Float), duration: Double,
                         curve: @escaping (Float) -> Float, done: (() -> Void)? = nil) {
        animation = Animation(start: Main.now, duration: duration, from: (alpha, offset), to: target,
                              curve: curve, done: done)
        tick()
    }

    private func tick() {
        Main.cancel(frameTimer)
        frameTimer = nil
        guard let a = animation else { return }
        let t = Float(min(1, (Main.now - a.start) / max(a.duration, 0.001)))
        let e = a.curve(t)
        alpha = a.from.alpha + (a.to.alpha - a.from.alpha) * e
        offset = a.from.offset + (a.to.offset - a.from.offset) * e
        apply()
        if t >= 1 {
            animation = nil
            a.done?()
        } else {
            frameTimer = Main.after(1.0 / 60) { [weak self] in self?.tick() }
        }
    }
}
