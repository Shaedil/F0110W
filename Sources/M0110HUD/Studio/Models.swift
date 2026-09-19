import Foundation

/// A single behavior binding in a keymap slot (e.g. `&kp A`).
struct BehaviorBinding: Equatable {
    var behaviorID: Int32
    var param1: UInt32
    var param2: UInt32

    static let empty = BehaviorBinding(behaviorID: 0, param1: 0, param2: 0)

    var encoded: [UInt8] {
        var w = ProtobufWriter()
        w.sint32(1, behaviorID)
        w.uint32(2, param1)
        w.uint32(3, param2)
        return w.bytes
    }

    static func decode(_ bytes: [UInt8]) throws -> BehaviorBinding {
        var r = ProtobufReader(bytes)
        var out = BehaviorBinding.empty
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            switch (field, type) {
            case (1, .varint): out.behaviorID = ProtobufReader.unzigzag(try r.varint())
            case (2, .varint): out.param1 = UInt32(truncatingIfNeeded: try r.varint())
            case (3, .varint): out.param2 = UInt32(truncatingIfNeeded: try r.varint())
            default: try r.skip(type)
            }
        }
        return out
    }
}

struct KeymapLayer: Identifiable {
    var id: UInt32
    var name: String
    var bindings: [BehaviorBinding]

    static func decode(_ bytes: [UInt8]) throws -> KeymapLayer {
        var r = ProtobufReader(bytes)
        var layer = KeymapLayer(id: 0, name: "", bindings: [])
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            switch (field, type) {
            case (1, .varint): layer.id = UInt32(truncatingIfNeeded: try r.varint())
            case (2, .lengthDelimited): layer.name = try r.stringField()
            case (3, .lengthDelimited): layer.bindings.append(try BehaviorBinding.decode(r.bytesField()))
            default: try r.skip(type)
            }
        }
        return layer
    }
}

struct Keymap {
    var layers: [KeymapLayer] = []
    var availableLayers: UInt32 = 0
    var maxLayerNameLength: UInt32 = 0

    static func decode(_ bytes: [UInt8]) throws -> Keymap {
        var r = ProtobufReader(bytes)
        var km = Keymap()
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            switch (field, type) {
            case (1, .lengthDelimited): km.layers.append(try KeymapLayer.decode(r.bytesField()))
            case (2, .varint): km.availableLayers = UInt32(truncatingIfNeeded: try r.varint())
            case (3, .varint): km.maxLayerNameLength = UInt32(truncatingIfNeeded: try r.varint())
            default: try r.skip(type)
            }
        }
        return km
    }
}

/// Key geometry as the firmware reports it, in hundredths of a key unit.
struct KeyPhysicalAttrs {
    var width: Int32 = 100
    var height: Int32 = 100
    var x: Int32 = 0
    var y: Int32 = 0
    var r: Int32 = 0
    var rx: Int32 = 0
    var ry: Int32 = 0

    static func decode(_ bytes: [UInt8]) throws -> KeyPhysicalAttrs {
        var r = ProtobufReader(bytes)
        var k = KeyPhysicalAttrs()
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            guard type == .varint else { try r.skip(type); continue }
            let v = ProtobufReader.unzigzag(try r.varint())
            switch field {
            case 1: k.width = v
            case 2: k.height = v
            case 3: k.x = v
            case 4: k.y = v
            case 5: k.r = v
            case 6: k.rx = v
            case 7: k.ry = v
            default: break
            }
        }
        return k
    }
}

struct PhysicalLayout {
    var name: String = ""
    var keys: [KeyPhysicalAttrs] = []

    static func decode(_ bytes: [UInt8]) throws -> PhysicalLayout {
        var r = ProtobufReader(bytes)
        var layout = PhysicalLayout()
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            switch (field, type) {
            case (1, .lengthDelimited): layout.name = try r.stringField()
            case (2, .lengthDelimited): layout.keys.append(try KeyPhysicalAttrs.decode(r.bytesField()))
            default: try r.skip(type)
            }
        }
        return layout
    }
}

struct PhysicalLayouts {
    var activeIndex: UInt32 = 0
    var layouts: [PhysicalLayout] = []

    static func decode(_ bytes: [UInt8]) throws -> PhysicalLayouts {
        var r = ProtobufReader(bytes)
        var out = PhysicalLayouts()
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            switch (field, type) {
            case (1, .varint): out.activeIndex = UInt32(truncatingIfNeeded: try r.varint())
            case (2, .lengthDelimited): out.layouts.append(try PhysicalLayout.decode(r.bytesField()))
            default: try r.skip(type)
            }
        }
        return out
    }
}

struct DeviceInfo {
    var name: String = ""
    var serialNumber: [UInt8] = []

    static func decode(_ bytes: [UInt8]) throws -> DeviceInfo {
        var r = ProtobufReader(bytes)
        var info = DeviceInfo()
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            switch (field, type) {
            case (1, .lengthDelimited): info.name = try r.stringField()
            case (2, .lengthDelimited): info.serialNumber = try r.bytesField()
            default: try r.skip(type)
            }
        }
        return info
    }
}

enum LockState: UInt32 {
    case locked = 0
    case unlocked = 1
}
