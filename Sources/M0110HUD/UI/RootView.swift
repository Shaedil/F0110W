import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case keys = "Keys"
    case gestures = "Gestures"
    case haptics = "Haptics"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: PixelIcon.Kind {
        switch self {
        case .keys: return .keys
        case .gestures: return .gestures
        case .haptics: return .haptics
        case .settings: return .settings
        }
    }

    /// Warm-leaning icon tints, in the Altar II palette.
    var tint: Color {
        switch self {
        case .keys: return Color(red: 0.85, green: 0.72, blue: 0.50)
        case .gestures: return Color(red: 0.93, green: 0.55, blue: 0.30)
        case .haptics: return Color(red: 0.80, green: 0.50, blue: 0.85)
        case .settings: return Color(red: 0.90, green: 0.45, blue: 0.36)
        }
    }
}

struct RootView: View {
    @ObservedObject var controller: KeyboardController
    @State private var pane: Pane
    @State private var sidebarVisible = true
    @Environment(\.classicSnapshot) private var snapshot
    var onClose: (() -> Void)?
    /// The window sizes itself to what is on screen, so it has to hear when
    /// that changes. Absent for offscreen renders, which have no window.
    var onLayoutChange: ((WindowLayout) -> Void)?

    /// Sidebar metrics. It floats over the content rather than dividing the
    /// window, so it needs margins of its own on all four sides.
    private static let sidebarWidth: CGFloat = 214
    /// Small, because the traffic lights live *inside* the sidebar, the way
    /// Finder does it. AppKit puts them at a fixed offset from the window's
    /// corner, so the panel has to reach nearly into that corner to enclose
    /// them; inset it much further and they end up sitting on the background
    /// beside the panel instead of on it.
    private static let sidebarInset: CGFloat = 8

    /// Total width the sidebar occupies, itself plus both margins. The window
    /// gives back exactly this much when the sidebar is hidden, which is what
    /// leaves the board the same size in both states.
    static var sidebarSpan: CGFloat { sidebarWidth + sidebarInset * 2 }
    /// Height inside the sidebar reserved for the window controls.
    private static let trafficLightBand: CGFloat = 44
    /// How far the content is held off the window's leading edge while the
    /// sidebar is showing.
    private var contentInset: CGFloat {
        sidebarVisible ? Self.sidebarSpan : 0
    }

    init(controller: KeyboardController,
         initialPane: Pane = .keys,
         onClose: (() -> Void)? = nil,
         onLayoutChange: ((WindowLayout) -> Void)? = nil) {
        self.controller = controller
        self._pane = State(initialValue: initialPane)
        self.onClose = onClose
        self.onLayoutChange = onLayoutChange
    }

    /// The state the window's size is computed from.
    ///
    /// The picker is drawn only on the Keys pane, and only once there is a
    /// board to draw it under. Sizing the window from the selection alone would
    /// leave it tall on the Settings pane, or while the keyboard is locked and
    /// the board is a placeholder.
    private var windowLayout: WindowLayout {
        WindowLayout(
            sidebarVisible: sidebarVisible,
            pickerOpen: pane == .keys
                        && !controller.displayKeys.isEmpty
                        && controller.selectedKey != nil)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ThemeBackground()

            detail
                .padding(.leading, contentInset)

            if sidebarVisible {
                floatingSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                // With the sidebar hidden its own copy goes with it, so this is
                // the only way back. It sits beside the window controls, which
                // are now over the content.
                toggleButton
                    .padding(.leading, MainWindowController.controlsTrailingX + 12)
                    .padding(.top, MainWindowController.controlCentreY
                                   - Self.toggleSize.height / 2)
            }
        }
        // The window uses `fullSizeContentView`, but SwiftUI still insets its
        // content by the title bar's safe area, which pushed the toggle a full
        // title bar below the traffic lights it is supposed to sit beside, and
        // everything else down with it. The theme paints under the title bar on
        // purpose, so the inset is not wanted here.
        .ignoresSafeArea(.container, edges: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: sidebarVisible)
        // Watched rather than fired from the toggle's action or the keycap's
        // tap, so every route into these states moves the window: the keyboard
        // shortcut, the picker's Done button, switching panes, a reload that
        // empties the board.
        .onChange(of: windowLayout) { layout in onLayoutChange?(layout) }
        .onAppear { if case .disconnected = controller.connection { controller.connect() } }
    }

    // MARK: - Sidebar

    /// A floating sidebar: a rounded slab inset from every edge, laid over the
    /// content rather than partitioning the window, the way macOS 26 does it.
    ///
    /// The blur comes from AppKit. SwiftUI's own materials sample the window's
    /// backing, and over this theme's near-black gradient they resolve to flat
    /// grey. An `NSVisualEffectView` in `.withinWindow` mode blurs what is
    /// behind it, which is what the treatment needs.
    private var floatingSidebar: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return sidebarContent
            .frame(width: Self.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                ZStack {
                    // ImageRenderer cannot rasterise an NSViewRepresentable, so
                    // offscreen snapshots fall back to a plain fill.
                    if !snapshot {
                        VisualEffectBackground(material: .sidebar)
                    }
                    shape.fill(Theme.sidebarFloating)
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(Theme.sidebarFloatingStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.42), radius: 18, y: 7)
            .padding(Self.sidebarInset)
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            deviceCard
            VStack(spacing: 2) {
                ForEach(Pane.allCases) { item in row(item) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        // Leave the top of the panel to the window controls.
        .padding(.top, Self.trafficLightBand)
        // Put the toggle at the other end of that same row, inside the sidebar
        // rather than floating on the content beside it.
        .overlay(alignment: .topTrailing) {
            toggleButton
                .padding(.trailing, 10)
                .padding(.top, MainWindowController.controlCentreY - Self.sidebarInset
                               - Self.toggleSize.height / 2)
        }
    }

    private static let toggleSize = CGSize(width: 28, height: 22)

    /// The toggle, without placement, since it is mounted in two different
    /// places. While the sidebar is open it belongs to the sidebar, on the same
    /// row as the window controls and at the far end of it; hidden, it has to
    /// live on the content instead, because its host has gone.
    private var toggleButton: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button {
            sidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(sidebarVisible ? Theme.text : Theme.textDim)
                .frame(width: Self.toggleSize.width, height: Self.toggleSize.height)
                .background(shape.fill(Theme.key))
                .overlay(shape.strokeBorder(Theme.keyStroke, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    private func row(_ item: Pane) -> some View {
        let active = pane == item
        return HStack(spacing: 9) {
            PixelIcon(kind: item.icon, tint: item.tint)
                .frame(width: 16)
            Text(item.rawValue)
                .font(Theme.body.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.text : Theme.textDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Theme.key : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { pane = item }
    }

    /// Device thumbnail and connection state, like the Altar II sidebar header.
    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(indicator).frame(width: 7, height: 7)
                Text(deviceName)
                    .font(Theme.small.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            KeyboardThumbnail(keys: controller.displayKeys,
                              unitsWide: controller.displayWidth,
                              tint: Theme.text.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(Theme.key, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(connectionDetail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if case .failed = controller.connection {
                Button("Retry") { controller.connect() }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.panelStroke, lineWidth: 1)
        )
    }

    private var deviceName: String {
        if case .connected(_, let device) = controller.connection { return device }
        return "M0110"
    }

    private var indicator: Color {
        switch controller.connection {
        case .connected: return controller.lockState == .unlocked ? Theme.good : Theme.warn
        case .connecting: return Theme.warn
        case .failed: return Theme.bad
        case .disconnected: return Theme.textDim
        }
    }

    private var connectionDetail: String {
        switch controller.connection {
        case .disconnected: return "Not connected"
        case .connecting: return "Looking for the keyboard\u{2026}"
        case .connected(let port, _):
            let lock = controller.lockState == .unlocked ? "unlocked" : "locked"
            return "\((port as NSString).lastPathComponent) · \(lock)"
        case .failed(let why): return why
        }
    }

    // MARK: - Detail

    @ViewBuilder private var paneBody: some View {
        switch pane {
        case .keys: KeysPane(controller: controller)
        case .gestures: FeatureGapPane.gestures
        case .haptics: FeatureGapPane.haptics
        case .settings: SettingsPane()
        }
    }

    private var detail: some View {
        ClassicScroll {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    Text(pane.rawValue)
                        .font(Theme.pageTitle)
                        .foregroundStyle(Theme.text)
                    RacingStripes()
                        .frame(maxWidth: 220)
                    Spacer(minLength: 0)
                }
                paneBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            // Clear of the title bar and the sidebar toggle, both of which the
            // content now runs underneath.
            .padding(.top, 54)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
