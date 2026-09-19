import Foundation

/// Synthesised M0110A layout and keymap, so the interface can be rendered and
/// reviewed without the keyboard attached or unlocked.
///
/// Geometry mirrors `config/boards/shields/m0110/m0110-layouts.dtsi`, 79 keys
/// in hundredths of a key unit, so previews match what the firmware reports.
enum PreviewFixture {
    static func layout() -> PhysicalLayout {
        var keys: [KeyPhysicalAttrs] = []
        func key(_ w: Int32, _ x: Int32, _ y: Int32, h: Int32 = 100) {
            keys.append(KeyPhysicalAttrs(width: w, height: h, x: x, y: y))
        }

        // Row 0: number row + numpad top.
        for i in 0..<14 { key(100, Int32(i) * 100, 0) }
        for x in [1500, 1600, 1700, 1800] { key(100, Int32(x), 0) }
        // Row 1: tab row.
        key(150, 0, 100)
        for i in 0..<12 { key(100, 150 + Int32(i) * 100, 100) }
        for x in [1500, 1600, 1700, 1800] { key(100, Int32(x), 100) }
        // Row 2: home row, narrow ISO-style return.
        key(175, 0, 200)
        for i in 0..<11 { key(100, 175 + Int32(i) * 100, 200) }
        key(125, 1275, 200)
        for x in [1500, 1600, 1700, 1800] { key(100, Int32(x), 200) }
        // Row 3: shift row, ISO extra key, and Up.
        key(125, 0, 300)
        for i in 0..<12 { key(100, 125 + Int32(i) * 100, 300) }
        key(100, 1325, 300)
        for x in [1500, 1600, 1700] { key(100, Int32(x), 300) }
        // Row 4: modifiers, spacebar, arrows, numpad bottom.
        key(125, 0, 400)
        key(150, 125, 400)
        key(625, 275, 400)
        for x in [900, 1000, 1100, 1200] { key(100, Int32(x), 400) }
        key(200, 1500, 400)
        key(100, 1700, 400)
        key(100, 1800, 300, h: 200)

        return PhysicalLayout(name: "M0110A", keys: keys)
    }

    /// Base-layer keycodes in layout order, matching the shield's comment block.
    private static let usages: [UInt32] = {
        var u: [UInt32] = []
        func add(_ list: [UInt32]) { u += list }
        // ` 1..0 - = Bksp, then Clr KP= KP/ KP*
        add([0x35, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2D, 0x2E, 0x2A])
        add([0x53, 0x67, 0x54, 0x55])
        // Tab QWERTYUIOP [ ], then KP7 KP8 KP9 KP-
        add([0x2B, 0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18, 0x0C, 0x12, 0x13, 0x2F, 0x30])
        add([0x5F, 0x60, 0x61, 0x56])
        // Caps ASDFGHJKL ; ' Return, then KP4 KP5 KP6 KP+
        add([0x39, 0x04, 0x16, 0x07, 0x09, 0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x33, 0x34, 0x28])
        add([0x5C, 0x5D, 0x5E, 0x57])
        // LShift ISO ZXCVBNM , . / RAlt Up, then KP1 KP2 KP3.
        // Position 64 is RALT in config/m0110.keymap rather than a right Shift:
        // the dtsi's comment block says "RSh" but the bindings are authoritative.
        add([0xE1, 0x64, 0x1D, 0x1B, 0x06, 0x19, 0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0xE6, 0x52])
        add([0x59, 0x5A, 0x5B])
        // LCtrl LGui Space \ Left Right Down, then KP0 KP. KPEnter
        add([0xE0, 0xE3, 0x2C, 0x31, 0x50, 0x4F, 0x51])
        add([0x62, 0x63, 0x58])
        return u
    }()

    static func keymap() -> Keymap {
        let bindings = usages.map {
            BehaviorBinding(behaviorID: 5, param1: HIDKeycodes.encode(usage: $0), param2: 0)
        }
        return Keymap(layers: [KeymapLayer(id: 0, name: "Base", bindings: bindings),
                               KeymapLayer(id: 1, name: "Fn", bindings: bindings)],
                      availableLayers: 0,
                      maxLayerNameLength: 16)
    }

    /// Behaviour 5 is `&kp` on this firmware, whose param1 is a HID usage.
    static func behaviors() -> [Int32: BehaviorInfo] {
        [5: BehaviorInfo(id: 5, displayName: "Key Press", param1: .hidUsage)]
    }
}

extension KeyboardController {
    /// Fill in fixture data and pretend the link is up, for offscreen renders.
    func loadPreviewFixture() {
        connection = .connected(port: "/dev/cu.usbmodem1104", device: "M0110")
        lockState = .unlocked
        layout = PreviewFixture.layout()
        keymap = PreviewFixture.keymap()
        behaviors = PreviewFixture.behaviors()
        activeLayerIndex = 0
        selectedKey = 24
    }
}
