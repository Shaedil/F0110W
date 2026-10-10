import CM0110Win
import Foundation

/// The HUD on Windows: a layered window in the corner by the tray that slides
/// in, holds and fades, as the Mac's does under the menu bar. Showing it again
/// while it is up changes it in place and restarts the hold.
final class WinHUD {
    var config: Config
    private let text = GDIText()

    private var content: HUDContent?
    /// Where the window rests, and which way is towards the screen edge it
    /// slides in from.
    private var rest = (x: 0, y: 0)
    private var towardsEdge: Float = 1
    private var shown = false
    private var alpha: Float = 0
    /// How far from `rest` it is, towards the edge.
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

    /// The Mac's: a steep ease-out arriving, a plain ease leaving.
    private static let enter = 0.35
    private static let leave = 0.5
    private static func expoOut(_ t: Float) -> Float { t >= 1 ? 1 : 1 - pow(2, -10 * t) }
    private static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    init(config: Config) {
        self.config = config
    }

    var isVisible: Bool { shown && alpha > 0.01 }

    private var theme: HUDTheme {
        // System flyouts follow the taskbar's mode, not the apps'.
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
            // Caught fading out: come back up rather than starting over.
            animate(to: (1, 0), duration: 0.2, curve: Self.ease)
        }
        Main.cancel(holdTimer)
        holdTimer = Main.after(config.hudDuration) { [weak self] in self?.dismiss() }
        log("hud: \(kind.rawValue) \(name) \(battery.map { "\($0)%" } ?? "-")", verbose: config.verbose)
    }

    /// A battery reading landed while a HUD is up: fill it in, saying the same.
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

    /// Draws `content` for the screen the user is on and puts it up, in
    /// whatever state of its entrance or exit the HUD is in.
    private func present(_ content: HUDContent) {
        self.content = content
        let screen = m0110_current_screen()
        scale = Float(screen.dpi) / 96 * Float(config.scale)
        let image = HUDArt.render(content, metrics: WinHUDMetrics(scale: scale), theme: theme, text: text)

        // In the corner by the tray: along the right unless the taskbar is on
        // the left, at the bottom unless it is at the top, held off the edge
        // and the taskbar by the Settings pane's insets, in pixels at 96 DPI.
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
