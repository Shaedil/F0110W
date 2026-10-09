import SwiftUI

/// Width of the pane, so the board can be drawn as large as fits.
private struct PaneWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Live keymap editor: the layout in a rounded panel, with a keycode picker for
/// the selected key.
struct KeysPane: View {
    @ObservedObject var controller: KeyboardController

    /// How wide the board is drawn when there is room for it. Legends are sized
    /// in unit-hundredths, so they scale with this: one number sets both the
    /// keyboard's size and its type size.
    private static let preferredBoardWidth: CGFloat = 990
    /// Below this the drawing stops being readable, so the pane clips instead.
    private static let minimumBoardWidth: CGFloat = 420

    /// Width the pane has been given. Measured rather than assumed: at the
    /// window's minimum size, or with the sidebar showing, there is not always
    /// room for the preferred width, and a board wider than its container gets
    /// silently clipped rather than shrinking.
    @State private var paneWidth: CGFloat = preferredBoardWidth
    /// Show the modelled board rather than the drawing. Only the M0110 is
    /// modelled, so the M0110A always gets the drawing.
    @AppStorage("keyboard3D") private var prefers3D = true
    private var shows3D: Bool { prefers3D && controller.variant == .m0110 }

    private var boardWidth: CGFloat {
        // The Panel insets the board by 14 on each side.
        min(Self.preferredBoardWidth, max(Self.minimumBoardWidth, paneWidth - 28))
    }
    private var scale: CGFloat { boardWidth / CGFloat(max(controller.displayWidth, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            // The M0110's key table is hand-built and never empty, so keying
            // the explanation off the key list alone meant a locked or unloaded
            // keyboard showed a full board with every legend blank and nothing
            // saying why. The keymap is what is missing, so that is what
            // decides.
            if controller.displayKeys.isEmpty || controller.activeLayer == nil {
                emptyState
            } else {
                Panel(padding: 14,
                      // The 3D view leaves its own margin round the case.
                      verticalPadding: shows3D ? 24 : 42,
                      // The 3D board sits on the same dark stage as the
                      // other panes' board, so moving between them reads as
                      // one scene.
                      surface: shows3D ? Theme.panel : Theme.boardSurround,
                      stroke: shows3D ? Theme.panelStroke : Theme.boardSurroundStroke) {
                    // Full width, so the panel's edges line up with the
                    // picker's below it; the board centres inside.
                    Group { if shows3D { board3D } else { board } }
                        .frame(maxWidth: .infinity)
                }
                    // The board stops at its preferred width; centred in
                    // whatever the pane has beyond that, full screen included.
                    .frame(maxWidth: .infinity)
                if let position = controller.selectedKey {
                    KeycodePicker(controller: controller, keyPosition: position)
                }
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: PaneWidthKey.self, value: geo.size.width)
            }
        }
        .onPreferenceChange(PaneWidthKey.self) { width in
            if width > 0, abs(width - paneWidth) > 0.5 { paneWidth = width }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if controller.keymap.layers.count > 1 {
                SegmentPills(
                    options: Array(controller.keymap.layers.enumerated()).map {
                        ($0.offset, $0.element.name.isEmpty ? "Layer \($0.offset)" : $0.element.name)
                    },
                    selection: $controller.activeLayerIndex,
                    font: Theme.toolbar.weight(.medium),
                    padding: EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            }

            // In the toolbar rather than under the picker: the page does not
            // scroll, and a line appearing below it on every edit pushed the
            // whole layout down.
            if let status = controller.status {
                Text(status)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(status)
            }

            Spacer(minLength: 0)

            if controller.variant == .m0110 {
                SegmentPills(options: [(false, "2D"), (true, "3D")],
                             selection: $prefers3D,
                             font: Theme.toolbar.weight(.medium),
                             padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            ConnectionBadge(controller: controller)

            if controller.lockState == .locked, controller.connection.isConnected {
                Button("Unlock check") { controller.refreshLockState() }
                    .buttonStyle(PillButtonStyle())
            }

            if controller.pendingEdits > 0 {
                Button("Discard") { controller.discard() }
                    .buttonStyle(PillButtonStyle())
                Button("Save \(controller.pendingEdits)") { controller.save() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut("s")
            }
        }
    }

    private var emptyState: some View {
        Panel {
            VStack(alignment: .leading, spacing: 7) {
                Text(locked ? "Keyboard locked" : "No layout loaded")
                    .font(Theme.sectionTitle)
                    .foregroundStyle(Theme.text)
                Text(locked
                     ? "ZMK Studio refuses reads as well as writes while locked, so the keymap "
                       + "cannot be shown yet. Press the key bound to &studio_unlock and it "
                       + "will load on its own. The lock re-arms after ten minutes idle and "
                       + "whenever the link drops."
                     : "Connect the keyboard over USB or Bluetooth. The firmware binds Studio's "
                       + "RPC to whichever endpoint it is currently typing on, so a board plugged "
                       + "into USB will not answer over Bluetooth. Switch its output with "
                       + "the Fn-layer &out key if you want the wireless route.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                // With no link there is nothing to reload, so it reconnects.
                Button("Reload") {
                    if controller.connection.isConnected { controller.refresh() } else { controller.connect() }
                }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .padding(.top, 2)
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
    }

    private var locked: Bool {
        controller.connection.isConnected && controller.lockState == .locked
    }

    /// The modelled board, in the same box the drawing fills, so switching
    /// between them leaves the window and the picker where they were.
    private var board3D: some View {
        let bezel = controller.boardBezel
        let span = CGFloat(controller.displayWidth) + bezel.side * 2
        let box = BoardCase.size(unitsWide: controller.displayWidth,
                                 bezel: bezel, scale: boardWidth / span)
        return KeyboardStageView(controller: controller)
            .frame(width: box.width, height: box.height)
    }

    /// The drawn case, with the live matrix seated in its wells.
    private var board: some View {
        // Fit the whole case, margins included, into the available width.
        let bezel = controller.boardBezel
        let span = CGFloat(controller.displayWidth) + bezel.side * 2
        let unitScale = boardWidth / span
        // On the compact board the bezel is wider down the sides than across
        // the top, so the key field's origin is not one inset.
        let originX = bezel.side * unitScale
        let originY = bezel.top * unitScale
        let box = BoardCase.size(unitsWide: controller.displayWidth,
                                 bezel: bezel, scale: unitScale)

        return ZStack(alignment: .topLeading) {
            BoardCase(unitsWide: controller.displayWidth,
                      wells: controller.boardWells,
                      bezelPatches: controller.boardBezelPatches,
                      logoCell: controller.boardLogoCell,
                      scale: unitScale,
                      bezel: bezel)
            keycaps(originX: originX, originY: originY, scale: unitScale)
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        // Flatten the board into one Metal-rendered layer. Each of the ~58
        // keycaps casts its own shadow, and a shadow is an offscreen pass, so
        // every redraw of this pane was ~58 of them, which is what made
        // dragging the window judder. The board only changes when the keymap or
        // the selection does, so there is nothing to lose by rasterising it.
        .drawingGroup()
    }

    private func keycaps(originX: CGFloat, originY: CGFloat, scale: CGFloat) -> some View {
        // In unit-hundredths, like everything else, so the gap between caps and
        // the border around the block stay equal at any scale.
        let gap = BoardCase.keyGap * scale
        return ForEach(Array(controller.displayKeys.enumerated()), id: \.offset) { _, key in
            Keycap(legend: key.labeled ? controller.legend(forKeyAt: key.position) : .blank,
                   isSelected: controller.selectedKey == key.position,
                   isEditable: controller.canEdit && controller.acceptsKeycode(at: key.position),
                   isSpacebar: key.position == M0110Layout.spacebarPosition,
                   cutout: key.cutout,
                   scale: scale)
                .frame(width: CGFloat(key.attrs.width) * scale - gap,
                       height: CGFloat(key.attrs.height) * scale - gap)
                .offset(x: originX + CGFloat(key.attrs.x) * scale + gap / 2,
                        y: originY + CGFloat(key.attrs.y) * scale + gap / 2)
                .onTapGesture {
                    guard key.position != M0110Layout.unmapped else { return }
                    controller.selectedKey =
                        (controller.selectedKey == key.position) ? nil : key.position
                }
        }
    }
}

/// Grouped keycode chooser for the selected key.
private struct KeycodePicker: View {
    @ObservedObject var controller: KeyboardController
    let keyPosition: Int
    @State private var group = HIDKeycodes.groups.first!.0

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Key \(keyPosition)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(controller.behaviorName(at: keyPosition))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textDim)
                    if let current = controller.keycode(at: keyPosition) {
                        Text("· \(HIDKeycodes.name(for: current))")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Button("Done") { controller.selectedKey = nil }
                        .buttonStyle(PillButtonStyle(font: .system(size: 13, weight: .medium)))
                }

                if takesKeycode {
                    SegmentPills(options: HIDKeycodes.groups.map { ($0.0, $0.0) },
                                 selection: $group,
                                 font: .system(size: 13, weight: .medium),
                                 padding: EdgeInsets(top: 6, leading: 13, bottom: 6, trailing: 13))

                    let params = HIDKeycodes.groups.first { $0.0 == group }?.1 ?? []
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 8)], spacing: 8) {
                        ForEach(params, id: \.self) { param in
                            Button {
                                controller.rebind(keyPosition: keyPosition, to: param)
                            } label: {
                                Text(HIDKeycodes.label(for: param))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                            // Keycaps, not pills: these stand for keys.
                            .buttonStyle(PillButtonStyle(cornerRadius: 9, verticalPadding: 9,
                                                         font: .system(size: 14, weight: .medium)))
                            .help(HIDKeycodes.name(for: param))
                            .disabled(!controller.canEdit)
                        }
                    }
                } else {
                    Text("This slot is bound to \(controller.behaviorName(at: keyPosition)), whose "
                         + "parameter is not a keycode, so it cannot be remapped by picking a key. "
                         + "Changing the behaviour itself is not implemented.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var takesKeycode: Bool { controller.acceptsKeycode(at: keyPosition) }
}

/// Which keyboard the pane is talking to and how: a status light, the name,
/// the route, whether Studio is unlocked, and whether the keyboard is typing
/// to this computer. The reason a connect failed, and the button to try
/// again, are the empty state's; this stays one short line.
struct ConnectionBadge: View {
    @ObservedObject var controller: KeyboardController
    /// The keyboard's own link, for which profile it types to. Separate from
    /// the Studio link above: ZMK keeps every profile's link up, so Studio can
    /// be connected while the keystrokes go to another computer.
    @ObservedObject private var status = StatusModel.shared

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(indicator).frame(width: 8, height: 8)
            Text(name)
                .font(Theme.toolbar.weight(.semibold))
                .foregroundStyle(Theme.text)
            if let usb = route {
                Group {
                    if usb {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 14, weight: .medium))
                    } else {
                        BluetoothGlyph()
                            .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                            .frame(width: 8, height: 14)
                    }
                }
                .foregroundStyle(Theme.textDim)
                .accessibilityLabel(usb ? "USB" : "Bluetooth")
            }
            if route != nil {
                let unlocked = controller.lockState == .unlocked
                Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(unlocked ? Theme.textDim : Theme.warn)
                    .accessibilityLabel(unlocked ? "Unlocked" : "Locked")
            } else {
                Text(detail)
                    .font(Theme.toolbar)
                    .foregroundStyle(Theme.textDim)
            }
            // Shown whatever the Studio link is doing: Studio answers only on
            // the profile being typed to, so a keyboard moved elsewhere is
            // also the likeliest reason it is not connected.
            if let profile, let here = profile.typingHere {
                if here {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                        .accessibilityLabel("Typing to this Mac")
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text(profile.activeName())
                            .font(Theme.toolbar)
                    }
                    .foregroundStyle(Theme.warn)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Typing to \(profile.activeName())")
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.panelStroke, lineWidth: 1))
        .help(help)
    }

    private var name: String {
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

    /// True over USB, false over Bluetooth, nil with no link. Serial ports
    /// are device paths; the Bluetooth transport labels itself otherwise.
    private var route: Bool? {
        guard case .connected(let port, _) = controller.connection else { return nil }
        return port.hasPrefix("/dev/")
    }

    /// Said in words only while there is no link; once there is, the route
    /// and the lock are icons.
    private var detail: String {
        switch controller.connection {
        case .disconnected, .failed: return "Not connected"
        case .connecting: return "Connecting\u{2026}"
        case .connected: return ""
        }
    }

    /// The profile report, while the keyboard's own link is up to send one.
    private var profile: ProfileState? { status.linked ? status.profile : nil }

    /// The full story on hover: the port, or why nothing answered, then where
    /// the keystrokes are going.
    private var help: String {
        let link: String
        switch controller.connection {
        case .connected(let port, _):
            link = "\(port), Studio \(controller.lockState == .unlocked ? "unlocked" : "locked")"
        case .failed(let why): link = why
        case .connecting: link = "Looking for the keyboard"
        case .disconnected: link = "Not connected"
        }
        guard let typing = profile?.summary() else { return link }
        return "\(link)\n\(typing)"
    }
}

/// The Bluetooth rune. SF Symbols has no public one, so it is drawn: a spine
/// with two arrowheads off its right side, crossed by the two diagonals.
struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0, 0.27))
        path.addLine(to: p(1, 0.73))
        path.addLine(to: p(0.5, 1))
        path.addLine(to: p(0.5, 0))
        path.addLine(to: p(1, 0.27))
        path.addLine(to: p(0, 0.73))
        return path
    }
}
