import Foundation

/// What a behavior's first parameter means, which decides how a binding is
/// labelled and whether a keycode picker even applies.
enum ParamKind {
    case none
    case hidUsage
    case layerID
    case other
}

/// One behavior as the firmware describes it (`&kp`, `&mo`, `&bt` and so on).
struct BehaviorInfo {
    var id: Int32
    var displayName: String
    var param1: ParamKind

    /// Short label for bindings whose parameter isn't a keycode.
    var shortName: String {
        switch displayName.lowercased() {
        case let n where n.contains("transparent"): return "▽"
        case let n where n.contains("none"): return "✕"
        case let n where n.contains("momentary"): return "MO"
        case let n where n.contains("bluetooth"): return "BT"
        case let n where n.contains("output"): return "OUT"
        case let n where n.contains("bootloader"): return "BOOT"
        case let n where n.contains("unlock"): return "UNLK"
        case let n where n.contains("reset"): return "RST"
        default:
            // Initials keep long behaviour names inside a keycap.
            let words = displayName.split(separator: " ")
            if words.count > 1 { return words.compactMap { $0.first }.map(String.init).joined().uppercased() }
            return String(displayName.prefix(4))
        }
    }

    static func decode(_ bytes: [UInt8]) throws -> BehaviorInfo {
        var r = ProtobufReader(bytes)
        var info = BehaviorInfo(id: 0, displayName: "", param1: .none)
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            switch (field, type) {
            case (1, .varint):
                info.id = Int32(truncatingIfNeeded: try r.varint())
            case (2, .lengthDelimited):
                info.displayName = try r.stringField()
            case (3, .lengthDelimited):
                // BehaviorBindingParametersSet{param1 = 1 repeated}
                var set = ProtobufReader(try r.bytesField())
                while !set.isAtEnd {
                    let (f, t) = try set.nextField()
                    if f == 1, t == .lengthDelimited {
                        let kind = try Self.paramKind(set.bytesField())
                        // Any set that names a keycode wins, so `&kp` reads as
                        // a keycode even when other parameter sets exist.
                        if info.param1 == .none || kind == .hidUsage { info.param1 = kind }
                    } else {
                        try set.skip(t)
                    }
                }
            default:
                try r.skip(type)
            }
        }
        return info
    }

    /// BehaviorParameterValueDescription oneof: nil=2, constant=3, range=4,
    /// hid_usage=5, layer_id=6.
    private static func paramKind(_ bytes: [UInt8]) throws -> ParamKind {
        var r = ProtobufReader(bytes)
        var kind = ParamKind.other
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            switch field {
            case 5: try r.skip(type); return .hidUsage
            case 6: try r.skip(type); return .layerID
            case 2: try r.skip(type); kind = .none
            default: try r.skip(type)
            }
        }
        return kind
    }
}

extension ParamKind: Equatable {}

extension StudioClient {
    /// All behavior ids the firmware exposes.
    func listBehaviors() throws -> [UInt32] {
        var w = ProtobufWriter(); w.bool(1, true)
        let payload = try request(subsystem: 4, body: w.bytes)
        var r = ProtobufReader(try Self.subfield(1, in: payload))
        var ids: [UInt32] = []
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            if field == 1, type == .varint {
                ids.append(UInt32(truncatingIfNeeded: try r.varint()))
            } else if field == 1, type == .lengthDelimited {
                // Packed repeated varints.
                var packed = ProtobufReader(try r.bytesField())
                while !packed.isAtEnd { ids.append(UInt32(truncatingIfNeeded: try packed.varint())) }
            } else {
                try r.skip(type)
            }
        }
        return ids
    }

    func behaviorDetails(id: UInt32) throws -> BehaviorInfo {
        var inner = ProtobufWriter(); inner.uint32(1, id, skipZero: false)
        var w = ProtobufWriter(); w.message(2, inner.bytes)
        let payload = try request(subsystem: 4, body: w.bytes)
        return try BehaviorInfo.decode(try Self.subfield(2, in: payload))
    }

    /// Every behavior, keyed by id, for labelling bindings.
    func behaviorTable() throws -> [Int32: BehaviorInfo] {
        var table: [Int32: BehaviorInfo] = [:]
        for id in try listBehaviors() {
            if let info = try? behaviorDetails(id: id) {
                table[info.id] = info
                // Bindings carry sint32 ids; index the queried id too in case
                // the firmware reports a different one in the details.
                table[Int32(bitPattern: id)] = info
            }
        }
        return table
    }
}
