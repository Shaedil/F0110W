import Foundation

// What the window's page is told about the keyboard and its keymap, in JSON.
// The rules are the Mac editor's (KeyboardController's labels and legends,
// M0110Layout's geometry, BehaviorBinding.sending for what can be rebound),
// applied here so the page only draws.

/// A cap's printing, as CapLegend has it.
struct LegendJSON: Encodable, Equatable {
    var kind: String
    var text: String?
    var shifted: String?
    var base: String?

    init(_ legend: CapLegend) {
        switch legend {
        case .blank: kind = "blank"
        case .single(let s): kind = "single"; text = s
        case .pair(let shifted, let base): kind = "pair"; self.shifted = shifted; self.base = base
        case .word(let w): kind = "word"; text = w
        }
    }
}

/// One keymap slot on one layer.
struct SlotJSON: Encodable, Equatable {
    var legend: LegendJSON
    /// Whether picking a keycode can rebind it.
    var editable: Bool
    /// The firmware's name for its behaviour, as the picker's header shows it.
    var behavior: String
    /// The keycode it sends now, and that keycode's long name.
    var keycode: UInt32?
    var keycodeName: String?
}

struct LayerJSON: Encodable, Equatable {
    var name: String
    /// By firmware position, as a string: JSON keys are strings.
    var slots: [String: SlotJSON]
}

/// The board's fixed geometry, in hundredths of a key unit.
struct BoardJSON: Encodable {
    struct Key: Encodable { var position: Int; var x: Int32; var y: Int32; var w: Int32; var h: Int32 }
    struct Rect: Encodable { var x: Double; var y: Double; var w: Double; var h: Double }

    var keys: [Key]
    var unitsWide: Int32
    var unitsHigh: Int32
    var logoCell: Rect
    var bezelPatches: [Rect]
    var spacebarPosition: Int
    var unmapped: Int

    static let m0110: BoardJSON = {
        func rect(_ r: CGRect) -> Rect {
            Rect(x: Double(r.origin.x), y: Double(r.origin.y), w: Double(r.size.width), h: Double(r.size.height))
        }
        return BoardJSON(
            keys: M0110Layout.ansi.map {
                Key(position: $0.position, x: $0.attrs.x, y: $0.attrs.y, w: $0.attrs.width, h: $0.attrs.height)
            },
            unitsWide: M0110Layout.unitsWide,
            unitsHigh: 500,
            logoCell: rect(M0110Layout.appleLogoCell),
            bezelPatches: M0110Layout.bezelPatches.map(rect),
            spacebarPosition: M0110Layout.spacebarPosition,
            unmapped: M0110Layout.unmapped)
    }()
}

/// The key picker's groups, as HIDKeycodes has them.
struct PickerGroupJSON: Encodable {
    struct Key: Encodable { var value: UInt32; var label: String; var name: String }
    var name: String
    var keys: [Key]

    static let all: [PickerGroupJSON] = HIDKeycodes.groups.map { group in
        PickerGroupJSON(name: group.0, keys: group.1.map {
            Key(value: $0, label: HIDKeycodes.label(for: $0), name: HIDKeycodes.name(for: $0))
        })
    }
}

enum KeymapModel {
    /// Every layer's slots, for every position the board draws.
    static func layers(_ keymap: Keymap, behaviors: [Int32: BehaviorInfo]) -> [LayerJSON] {
        let positions = Set(M0110Layout.ansi.map(\.position))
        return keymap.layers.map { layer in
            var slots: [String: SlotJSON] = [:]
            for position in positions {
                slots[String(position)] = slot(position, in: layer, behaviors: behaviors)
            }
            return LayerJSON(name: layer.name, slots: slots)
        }
    }

    static func slot(_ position: Int, in layer: KeymapLayer, behaviors: [Int32: BehaviorInfo]) -> SlotJSON {
        guard position != M0110Layout.unmapped else {
            return SlotJSON(legend: LegendJSON(.single("\u{2014}")), editable: false,
                            behavior: "not in the matrix transform", keycode: nil, keycodeName: nil)
        }
        guard layer.bindings.indices.contains(position) else {
            return SlotJSON(legend: LegendJSON(.blank), editable: false, behavior: "\u{2014}", keycode: nil,
                            keycodeName: nil)
        }
        let binding = layer.bindings[position]
        let info = behaviors[binding.behaviorID]
        let keycode = info?.param1 == .hidUsage ? binding.param1 : nil
        return SlotJSON(legend: LegendJSON(legend(binding, info)),
                        editable: binding.sending(0, behaviors: behaviors) != nil,
                        behavior: info?.displayName ?? "behaviour \(binding.behaviorID)",
                        keycode: keycode,
                        keycodeName: keycode.map { HIDKeycodes.name(for: $0) })
    }

    /// KeyboardController.label(forKeyAt:).
    static func label(_ binding: BehaviorBinding, _ info: BehaviorInfo?) -> String {
        guard let info else {
            return binding.param1 == 0 ? "·" : "0x\(String(binding.param1, radix: 16))"
        }
        switch info.param1 {
        case .hidUsage:
            return HIDKeycodes.label(for: binding.param1)
        case .layerID:
            if binding.param2 != 0 { return HIDKeycodes.label(for: binding.param2) }
            return "\(info.shortName)\(binding.param1)"
        case .none, .other:
            return info.shortName
        }
    }

    /// KeyboardController.legend(forKeyAt:).
    static func legend(_ binding: BehaviorBinding, _ info: BehaviorInfo?) -> CapLegend {
        guard let info else { return CapLegend.forText(label(binding, nil)) }
        switch info.param1 {
        case .hidUsage:
            return usageLegend(binding.param1)
        case .layerID where binding.param2 != 0:
            return usageLegend(binding.param2)
        case .layerID, .none, .other:
            return CapLegend.forText(label(binding, info))
        }
    }

    private static func usageLegend(_ param: UInt32) -> CapLegend {
        let (page, usage) = HIDKeycodes.decode(param)
        guard page == HIDKeycodes.keyboardPage else { return CapLegend.forText(HIDKeycodes.label(for: param)) }
        return CapLegend.forUsage(usage)
    }
}
