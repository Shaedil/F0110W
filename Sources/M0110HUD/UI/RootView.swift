import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case keys = "Keyboard"
    case bluetooth = "Bluetooth"
    case battery = "Battery"
    case gestures = "Gestures"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: PixelIcon.Kind {
        switch self {
        case .keys: return .keys
        case .bluetooth: return .bluetooth
        case .battery: return .battery
        case .gestures: return .gestures
        case .settings: return .settings
        }
    }

    /// Warm-leaning icon tints, in the Altar II palette.
    var tint: Color {
        switch self {
        case .keys: return Color(red: 0.85, green: 0.72, blue: 0.50)
        case .bluetooth: return Color(red: 0.50, green: 0.68, blue: 0.93)
        case .battery: return Color(red: 0.55, green: 0.82, blue: 0.48)
        case .gestures: return Color(red: 0.93, green: 0.55, blue: 0.30)
        case .settings: return Color(red: 0.90, green: 0.45, blue: 0.36)
        }
    }
}

struct RootView: View {
    @ObservedObject var controller: KeyboardController
    @State private var pane: Pane
    @State private var sidebarVisible = true
    /// Full screen hides the window controls the collapsed toggle sits beside.
    @State private var fullScreen = false
    /// Read here too, so the 3D board can follow the Settings tab.
    @AppStorage("settingsTab") private var settingsTab: SettingsTab = .popup
    /// The keyboard's link and battery, for the 3D battery's gauge.
    @ObservedObject private var status = StatusModel.shared
    /// The detail pane's inset from its leading and trailing edges.
    private static let contentPadding: CGFloat = 28
    @Environment(\.classicSnapshot) private var snapshot
    var onClose: (() -> Void)?
    var onPaneChange: ((Pane) -> Void)?
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
         onPaneChange: ((Pane) -> Void)? = nil,
         onLayoutChange: ((WindowLayout) -> Void)? = nil) {
        self.controller = controller
        self._pane = State(initialValue: initialPane)
        self.onClose = onClose
        self.onPaneChange = onPaneChange
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
                // are now over the content; in full screen there are none, so
                // it lines up with the content's edge instead.
                toggleButton(onSidebar: false)
                    .padding(.leading, fullScreen ? Self.contentPadding
                                                  : MainWindowController.controlsTrailingX + 12)
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
        .onChange(of: pane) { pane in onPaneChange?(pane) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            fullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            fullScreen = false
        }
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
            toggleButton(onSidebar: true)
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
    ///
    /// Inked for the surface it is mounted on rather than for `sidebarVisible`,
    /// so the copy sliding out with the sidebar keeps the sidebar's colours.
    private func toggleButton(onSidebar: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button {
            sidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(onSidebar ? Theme.sidebarText : Theme.textDim)
                .frame(width: Self.toggleSize.width, height: Self.toggleSize.height)
                .background(shape.fill(onSidebar ? Theme.sidebarKey : Theme.key))
                .overlay(shape.strokeBorder(onSidebar ? Theme.sidebarKeyStroke : Theme.keyStroke,
                                            lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(onSidebar ? "Hide Sidebar" : "Show Sidebar")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    private func row(_ item: Pane) -> some View {
        let active = pane == item
        return HStack(spacing: 10) {
            PixelIcon(kind: item.icon, tint: Theme.sidebarIcon(item.tint))
                .frame(width: 18)
            Text(item.rawValue)
                .font(Theme.sidebarRow.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.sidebarText : Theme.sidebarTextDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Theme.sidebarKey : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { pane = item }
    }

    // MARK: - Detail

    @ViewBuilder private var paneBody: some View {
        switch pane {
        case .keys: KeysPane(controller: controller)
        case .bluetooth: BluetoothPane()
        case .battery: BatteryPane()
        case .gestures: FeatureGapPane.gestures
        case .settings: SettingsPane()
        }
    }

    /// The side panes are a column of text; the 3D board fills the rest of the
    /// width beside them. It stays mounted on the Keyboard pane, collapsed and
    /// paused, so leaving that pane flies the camera in from the whole board
    /// instead of starting cold.
    private var detail: some View {
        // The Clipboard and Logs tabs have nothing on the board worth
        // pointing at.
        let showStage = pane != .keys
            && !(pane == .settings && [.clipboard, .logs].contains(settingsTab))
        // No spacing: the column's own trailing padding is the gap, and on
        // the Keyboard pane any spacing would come out of the board's width.
        return HStack(alignment: .top, spacing: 0) {
            paneColumn
                .frame(maxWidth: pane == .keys ? .infinity : Self.paneColumnWidth,
                       alignment: .leading)
            // The Popup tab shows the popup itself rather than the board. The
            // stage stays underneath, paused, so the camera has somewhere to
            // fly from when another tab is picked.
            let popupDemo = pane == .settings && settingsTab == .popup
            // Centred in the column, so the short popup preview sits level
            // with the middle of the settings beside it.
            //
            // Swapped without animation: the column also changes width when
            // coming from a tab without the stage, and animating the two
            // together dragged a sliver of the board across the preview.
            ZStack {
                BoardStageView(focus: BoardFocus(pane: pane, settingsTab: settingsTab),
                               active: showStage && !popupDemo,
                               battery: status.linked ? status.battery : nil)
                    .opacity(popupDemo ? 0 : 1)
                if popupDemo {
                    PopupDemoView(active: showStage)
                }
            }
            .frame(maxWidth: showStage ? .infinity : 0)
            .opacity(showStage ? 1 : 0)
            .padding(.top, 54)
            .padding(.bottom, 24)
            .padding(.trailing, showStage ? Self.contentPadding : 0)
        }
    }

    /// The width side panes use for their text, matching `FeatureGapPane`.
    private static let paneColumnWidth: CGFloat = 620 + contentPadding * 2

    private var paneColumn: some View {
        // The Keyboard pane is laid out to fit; scrolling it only ever moved
        // it a few points and back.
        ClassicScroll(scrolls: pane != .keys) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    DitheredTitle(text: pane.rawValue)
                    RacingStripes(colour: pane.tint)
                        .frame(maxWidth: 220)
                    Spacer(minLength: 0)
                }
                paneBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.contentPadding)
            // Clear of the title bar and the sidebar toggle, both of which the
            // content now runs underneath.
            .padding(.top, 54)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
