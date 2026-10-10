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

    /// Icon tints from the Altar II palette.
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
    @ObservedObject private var status = StatusModel.shared
    private static let contentPadding: CGFloat = 28
    @Environment(\.classicSnapshot) private var snapshot
    var onClose: (() -> Void)?
    var onPaneChange: ((Pane) -> Void)?
    /// Nil for offscreen renders, which have no window.
    var onLayoutChange: ((WindowLayout) -> Void)?

    private static let sidebarWidth: CGFloat = 214
    /// Small so the panel reaches into the window corner and encloses the
    /// traffic lights, which AppKit places at a fixed offset.
    private static let sidebarInset: CGFloat = 8

    /// Sidebar plus both margins. The window shrinks by this much when the
    /// sidebar hides.
    static var sidebarSpan: CGFloat { sidebarWidth + sidebarInset * 2 }
    /// Height inside the sidebar reserved for the window controls.
    private static let trafficLightBand: CGFloat = 44
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

    /// The picker only shows on the Keys pane once a board is drawn, so a
    /// selected key alone does not open it.
    private var windowLayout: WindowLayout {
        WindowLayout(
            sidebarVisible: sidebarVisible,
            pickerOpen: pane == .keys
                        && !controller.displayKeys.isEmpty
                        && controller.selectedKey != nil)
    }

    var body: some View {
        ChronosSky { content }
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            ThemeBackground()

            detail
                .padding(.leading, contentInset)

            if sidebarVisible {
                floatingSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                // The only way back once the sidebar is hidden. It sits beside
                // the window controls, or at the content edge in full screen.
                toggleButton(onSidebar: false)
                    .padding(.leading, fullScreen ? Self.contentPadding
                                                  : MainWindowController.controlsTrailingX + 12)
                    .padding(.top, MainWindowController.controlCentreY
                                   - Self.toggleSize.height / 2)
            }
        }
        // SwiftUI still insets by the title bar's safe area under
        // `fullSizeContentView`, which pushed everything a title bar too low.
        .ignoresSafeArea(.container, edges: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: sidebarVisible)
        // Watched here, so every path that changes the layout resizes the window.
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

    /// The blur is AppKit's. SwiftUI materials turn flat grey over this theme's
    /// near-black gradient, but an `NSVisualEffectView` in `.withinWindow` mode
    /// blurs what is behind it.
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
                    PrismWash(shape: shape)
                }
                .clipShape(shape)
            }
            .overlay(PrismRim(shape: shape))
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
        .padding(.top, Self.trafficLightBand)
        .overlay(alignment: .topTrailing) {
            toggleButton(onSidebar: true)
                .padding(.trailing, 10)
                .padding(.top, MainWindowController.controlCentreY - Self.sidebarInset
                               - Self.toggleSize.height / 2)
        }
    }

    private static let toggleSize = CGSize(width: 28, height: 22)

    /// Mounted on the sidebar when open and on the content when hidden. Colors
    /// follow `onSidebar` so the copy sliding out keeps the sidebar colors.
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

    /// The 3D board fills the width beside the side panes. It stays mounted,
    /// collapsed and paused, on the Keyboard pane so the camera can fly in from
    /// the whole board when you leave it.
    private var detail: some View {
        // The Clipboard and Logs tabs have nothing to show on the board.
        let showStage = pane != .keys
            && !(pane == .settings && [.clipboard, .logs].contains(settingsTab))
        // No spacing, since on the Keyboard pane it would come out of the
        // board's width.
        return HStack(alignment: .top, spacing: 0) {
            paneColumn
                .frame(maxWidth: pane == .keys ? .infinity : Self.paneColumnWidth,
                       alignment: .leading)
            // The Popup tab shows the popup instead of the board. The stage
            // stays underneath, paused, so the camera can fly from it later.
            let popupDemo = pane == .settings && settingsTab == .popup
            // Swapped without animation. The column can change width at the
            // same time, and animating both dragged part of the board across
            // the preview.
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
        // The Keyboard pane is laid out to fit, so it does not scroll.
        ClassicScroll(scrolls: pane != .keys) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    DitheredTitle(text: pane.rawValue)
                    RacingStripes()
                        .frame(maxWidth: 220)
                    Spacer(minLength: 0)
                }
                paneBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.contentPadding)
            // Clears the title bar and the sidebar toggle.
            .padding(.top, 54)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
