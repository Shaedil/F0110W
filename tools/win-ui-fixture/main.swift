import Foundation

// Writes WindowsUI/fixture.json: what the Windows app sends its page, built by
// the same Swift (KeymapModel, M0110Layout, CapLegend, HIDKeycodes) from this
// repo's keymap, so the page can be previewed in a browser on a Mac.

let kp: Int32 = 5, trans: Int32 = 1, bt: Int32 = 2, out: Int32 = 3, lt: Int32 = 4
let unlock: Int32 = 6, boot: Int32 = 7
let behaviors: [Int32: BehaviorInfo] = [
    kp: BehaviorInfo(id: kp, displayName: "Key Press", param1: .hidUsage),
    trans: BehaviorInfo(id: trans, displayName: "Transparent", param1: .none),
    bt: BehaviorInfo(id: bt, displayName: "Bluetooth", param1: .other),
    out: BehaviorInfo(id: out, displayName: "Output Selection", param1: .other),
    lt: BehaviorInfo(id: lt, displayName: "Layer-Tap", param1: .layerID),
    unlock: BehaviorInfo(id: unlock, displayName: "Studio Unlock", param1: .none),
    boot: BehaviorInfo(id: boot, displayName: "Bootloader", param1: .none),
]

func key(_ usage: UInt32) -> BehaviorBinding { BehaviorBinding(behaviorID: kp, param1: usage, param2: 0) }
func consumer(_ usage: UInt32) -> BehaviorBinding {
    BehaviorBinding(behaviorID: kp, param1: HIDKeycodes.encode(page: HIDKeycodes.consumerPage, usage: usage), param2: 0)
}
let t = BehaviorBinding(behaviorID: trans, param1: 0, param2: 0)

func layer(_ id: UInt32, _ name: String, _ slots: [Int: BehaviorBinding]) -> KeymapLayer {
    var bindings = Array(repeating: t, count: 79)
    for (position, binding) in slots { bindings[position] = binding }
    return KeymapLayer(id: id, name: name, bindings: bindings)
}

func k(_ usages: [UInt32], from start: Int) -> [Int: BehaviorBinding] {
    Dictionary(uniqueKeysWithValues: usages.enumerated().map { (start + $0.offset, key(HIDKeycodes.encode(usage: $0.element))) })
}

var base: [Int: BehaviorBinding] = [:]
base.merge(k([0x35, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2D, 0x2E, 0x2A], from: 0)) { $1 }
base.merge(k([0x2B, 0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18, 0x0C, 0x12, 0x13, 0x2F, 0x30], from: 18)) { $1 }
base.merge(k([0x39, 0x04, 0x16, 0x07, 0x09, 0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x33, 0x34, 0x28], from: 35)) { $1 }
base.merge(k([0xE1], from: 52)) { $1 }
base.merge(k([0x1D, 0x1B, 0x06, 0x19, 0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0xE5], from: 54)) { $1 }
base.merge(k([0xE0, 0xE3, 0x2C], from: 69)) { $1 }
base[72] = BehaviorBinding(behaviorID: lt, param1: 1, param2: HIDKeycodes.encode(usage: 0x31))

var fn: [Int: BehaviorBinding] = [:]
fn.merge(k([0x29, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x4C], from: 0)) { $1 }
for (n, position) in (19...23).enumerated() { fn[position] = BehaviorBinding(behaviorID: bt, param1: 3, param2: UInt32(n)) }
fn[24] = BehaviorBinding(behaviorID: out, param1: 1, param2: 0)
fn[25] = BehaviorBinding(behaviorID: out, param1: 2, param2: 0)
fn.merge(k([0x46, 0x47, 0x48, 0x52, 0x49], from: 26)) { $1 }
fn[36] = consumer(0xEA); fn[37] = consumer(0xE9); fn[38] = consumer(0xE2)
fn.merge(k([0x4A, 0x4B, 0x50, 0x4F], from: 43)) { $1 }
fn[54] = BehaviorBinding(behaviorID: unlock, param1: 0, param2: 0)
fn[55] = BehaviorBinding(behaviorID: boot, param1: 0, param2: 0)
fn[58] = BehaviorBinding(behaviorID: bt, param1: 0, param2: 0)
fn.merge(k([0x4D, 0x4E, 0x51], from: 61)) { $1 }

let keymap = Keymap(layers: [layer(0, "Base", base), layer(1, "Fn", fn)], availableLayers: 0, maxLayerNameLength: 16)

struct Fixture: Encodable {
    var board = BoardJSON.m0110
    var picker = PickerGroupJSON.all
    var layers: [LayerJSON]
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let data = try encoder.encode(Fixture(layers: KeymapModel.layers(keymap, behaviors: behaviors)))
let path = CommandLine.arguments[1]
try data.write(to: URL(fileURLWithPath: path))
print("wrote \(path) (\(data.count) bytes)")
