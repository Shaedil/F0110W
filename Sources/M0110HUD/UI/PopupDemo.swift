import AppKit
import SwiftUI

/// The Popup tab's preview: the top-right corner of the screen at actual size,
/// with the real `HUDView` arriving and leaving on a loop at the settings the
/// sliders beside it are making.
///
/// The settings themselves are read at launch, so without this the only way to
/// see what a slider did was to relaunch and wait for the keyboard to connect.
struct PopupDemoView: View {
    /// False while hidden, so the loop and the HUD's board stop.
    var active = true

    @AppStorage("scale") private var scale: Double = 1.0
    @AppStorage("insetX") private var insetX: Double = 110
    @AppStorage("insetY") private var insetY: Double = 6
    @AppStorage("hudDuration") private var duration: Double = 3.2
    @AppStorage("deviceName") private var deviceName: String = "M0110"
    @Environment(\.classicSnapshot) private var snapshot

    /// About the height of the popup's own controls beside it: enough for
    /// the menu bar and the popup at the default scale.
    static let height: CGFloat = 200

    @State private var visible = false
    /// Which sample the loop is on; each pass shows the next one.
    @State private var step = 0

    private struct Sample {
        let kind: HUDKind
        let battery: Int?
        let detail: String?
    }

    private var samples: [Sample] {
        [Sample(kind: .connected, battery: 72, detail: nil),
         Sample(kind: .lowBattery, battery: 14, detail: nil),
         Sample(kind: .movedAway, battery: nil, detail: ProfileNames.name(for: 1))]
    }

    private var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    /// The real menu bar's height, which is taller on a notched display.
    private var menuBarHeight: CGFloat {
        guard let screen else { return 24 }
        return min(max(screen.frame.maxY - screen.visibleFrame.maxY, 24), 40)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        GeometryReader { geo in
            // Actual size unless the HUD would run off the left or the
            // bottom; then the whole corner shrinks together so it stays in
            // view.
            let hudWidth = 240 * scale
            let hudBottom = menuBarHeight + insetY + 46 * scale + 20 * scale
            let zoom = min(1, (geo.size.width - 24) / (insetX + hudWidth + 24),
                           (geo.size.height - 36) / hudBottom)
            let sample = samples[step % samples.count]

            ZStack(alignment: .topTrailing) {
                wallpaper
                menuBar
                if !snapshot {
                    HUDPreview(kind: sample.kind, battery: sample.battery, detail: sample.detail,
                               name: deviceName.isEmpty ? "M0110" : deviceName,
                               scale: scale, playing: visible && active,
                               hold: max(duration, 0.5))
                        .id(scale)
                        .fixedSize()
                        .shadow(color: .black.opacity(0.28), radius: 12 * scale, y: 4 * scale)
                        .opacity(visible ? 1 : 0)
                        .offset(x: visible ? 0 : 26 * scale)
                        .padding(.top, menuBarHeight + insetY)
                        .padding(.trailing, insetX)
                }
            }
            .frame(width: geo.size.width / zoom, height: geo.size.height / zoom,
                   alignment: .topTrailing)
            .scaleEffect(zoom, anchor: .topTrailing)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Preview at these settings")
                .font(Theme.small.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .padding(14)
        }
        .frame(height: Self.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.panelStroke, lineWidth: 1))
        // The wallpaper is laid out at the screen's full size and only
        // clipped to the panel, and clipping does not stop hit-testing: left
        // alone, its invisible overhang sat on top of the sliders.
        .allowsHitTesting(false)
        .task(id: active) { await loop() }
    }

    /// Arrive, hold for the configured time, fade out, pause, next sample.
    private func loop() async {
        guard active else { visible = false; return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.timingCurve(0.19, 1, 0.22, 1, duration: 0.4)) { visible = true }
            try? await Task.sleep(nanoseconds: UInt64(max(duration, 0.5) * 1_000_000_000))
            guard !Task.isCancelled else { break }
            withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: HUDController.fadeOut)) {
                visible = false
            }
            try? await Task.sleep(nanoseconds: UInt64(HUDController.fadeOut * 1_000_000_000))
            step += 1
        }
    }

    /// The desktop picture, laid out at the screen's size and anchored to its
    /// top-right, so this panel is a window onto that corner.
    @ViewBuilder private var wallpaper: some View {
        let size = screen?.frame.size ?? CGSize(width: 1512, height: 982)
        if let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height, alignment: .topTrailing)
        } else {
            LinearGradient(colors: [Color(red: 0.24, green: 0.33, blue: 0.52),
                                    Color(red: 0.55, green: 0.42, blue: 0.48)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
                .frame(width: size.width, height: size.height)
        }
    }

    /// The right end of a menu bar: the status items and the clock.
    private var menuBar: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "keyboard")
            Image(systemName: "battery.100percent")
            Image(systemName: "wifi")
            Image(systemName: "magnifyingglass")
            Image(systemName: "switch.2")
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                                              .hour().minute()))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: menuBarHeight)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.22))
    }
}

/// The HUD's own view in a capsule of vibrancy, as `HUDController` builds it,
/// minus the panel: blurring what is behind it in this window instead of
/// behind the window.
private struct HUDPreview: NSViewRepresentable {
    let kind: HUDKind
    let battery: Int?
    let detail: String?
    let name: String
    let scale: Double
    let playing: Bool
    /// How long the sample stays up, which a crumble times its end to.
    let hold: TimeInterval

    final class Host: NSView {
        let hud: HUDView
        let metrics: HUDMetrics
        var playing = false

        init(metrics: HUDMetrics) {
            self.metrics = metrics
            hud = HUDView(metrics: metrics)
            super.init(frame: .zero)
            let effect = NSVisualEffectView()
            effect.material = .toolTip
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = metrics.cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            for view in [effect, hud] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: trailingAnchor),
                    view.topAnchor.constraint(equalTo: topAnchor),
                    view.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
            }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var intrinsicContentSize: NSSize { hud.preferredSize }
    }

    func makeNSView(context: Context) -> Host {
        Host(metrics: HUDMetrics(scale: CGFloat(scale)))
    }

    func updateNSView(_ host: Host, context: Context) {
        let lowThreshold = UserDefaults.standard.object(forKey: "lowThreshold") as? Int ?? 20
        host.hud.configure(kind: kind, name: name, battery: battery,
                           lowThreshold: lowThreshold, detail: detail,
                           canMoveBack: kind == .movedAway)
        host.invalidateIntrinsicContentSize()
        // Start the board's motion each time the HUD arrives, as the real one
        // does, and let it rest while it is away.
        if playing && !host.playing {
            let style = HUDStyle.defaults[kind]!
            host.hud.setSpinning(true)
            host.hud.animateBoard(style, battery: battery,
                                  reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                  hold: hold)
        } else if !playing && host.playing {
            host.hud.setSpinning(false)
        }
        host.playing = playing
    }
}
