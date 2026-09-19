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
                      verticalPadding: 42,
                      surface: Theme.boardSurround,
                      stroke: Theme.boardSurroundStroke) { board }
                if let position = controller.selectedKey {
                    KeycodePicker(controller: controller, keyPosition: position)
                }
            }
            if let status = controller.status {
                Text(status)
                    .font(Theme.small)
                    .foregroundStyle(Theme.textDim)
                    .textSelection(.enabled)
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
            SegmentPills(options: KeyboardVariant.allCases.map { ($0, $0.rawValue) },
                         selection: $controller.variant)

            if controller.keymap.layers.count > 1 {
                SegmentPills(
                    options: Array(controller.keymap.layers.enumerated()).map {
                        ($0.offset, $0.element.name.isEmpty ? "Layer \($0.offset)" : $0.element.name)
                    },
                    selection: $controller.activeLayerIndex)
            }

            Spacer()

            if controller.lockState == .locked, controller.connection.isConnected {
                Label("Locked", systemImage: "lock.fill")
                    .font(Theme.small)
                    .foregroundStyle(Theme.warn)
                Button("Unlock check") { controller.refreshLockState() }
                    .buttonStyle(PillButtonStyle())
            }

            Text("\(controller.presentKeyCount) keys")
                .font(Theme.readout)
                .foregroundStyle(Theme.textDim)

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
                Button("Reload") { controller.refresh() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .padding(.top, 2)
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
    }

    private var locked: Bool {
        controller.connection.isConnected && controller.lockState == .locked
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
                        .font(Theme.sectionTitle)
                        .foregroundStyle(Theme.text)
                    Text(controller.behaviorName(at: keyPosition))
                        .font(Theme.small)
                        .foregroundStyle(Theme.textDim)
                    if takesKeycode, let current {
                        Text("· \(HIDKeycodes.name(for: current))")
                            .font(Theme.small)
                            .foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Button("Done") { controller.selectedKey = nil }
                        .buttonStyle(PillButtonStyle())
                }

                if takesKeycode {
                    SegmentPills(options: HIDKeycodes.groups.map { ($0.0, $0.0) },
                                 selection: $group)

                    let usages = HIDKeycodes.groups.first { $0.0 == group }?.1 ?? []
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], spacing: 6) {
                        ForEach(usages, id: \.self) { usage in
                            Button {
                                controller.rebind(keyPosition: keyPosition, to: usage)
                            } label: {
                                Text(HIDKeycodes.keyboard[usage] ?? "0x\(String(usage, radix: 16))")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PillButtonStyle())
                            .help(HIDKeycodes.name(for: HIDKeycodes.encode(usage: usage)))
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

    private var current: UInt32? {
        guard let layer = controller.activeLayer,
              layer.bindings.indices.contains(keyPosition) else { return nil }
        return layer.bindings[keyPosition].param1
    }
}
