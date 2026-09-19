import Foundation

/// Minimal protobuf wire-format codec, covering exactly the field kinds the ZMK
/// Studio messages use. Hand-rolled deliberately: pulling in SwiftProtobuf would
/// add a `protoc-gen-swift` toolchain step and a network-fetched SwiftPM
/// dependency, and this app needs about a dozen message shapes.
enum WireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

struct ProtobufWriter {
    private(set) var bytes = [UInt8]()

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out = [UInt8]()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Protobuf zigzag encoding, used by `sint32` fields.
    static func zigzag(_ value: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: (value << 1) ^ (value >> 31)))
    }

    private mutating func tag(_ field: Int, _ type: WireType) {
        bytes += Self.varint(UInt64(field) << 3 | UInt64(type.rawValue))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        // proto3 omits false, but Studio's `oneof` members are bool-typed markers
        // whose presence is the signal, so always emit.
        tag(field, .varint)
        bytes += Self.varint(value ? 1 : 0)
    }

    mutating func uint32(_ field: Int, _ value: UInt32, skipZero: Bool = true) {
        if value == 0 && skipZero { return }
        tag(field, .varint)
        bytes += Self.varint(UInt64(value))
    }

    /// `int32`: plain varint, not zigzag.
    mutating func int32(_ field: Int, _ value: Int32, skipZero: Bool = true) {
        if value == 0 && skipZero { return }
        tag(field, .varint)
        bytes += Self.varint(UInt64(UInt32(bitPattern: value)))
    }

    /// `sint32`: zigzag varint.
    mutating func sint32(_ field: Int, _ value: Int32, skipZero: Bool = true) {
        if value == 0 && skipZero { return }
        tag(field, .varint)
        bytes += Self.varint(Self.zigzag(value))
    }

    mutating func message(_ field: Int, _ body: [UInt8]) {
        tag(field, .lengthDelimited)
        bytes += Self.varint(UInt64(body.count))
        bytes += body
    }

    mutating func string(_ field: Int, _ value: String) {
        message(field, Array(value.utf8))
    }
}

/// Forward-only reader over a protobuf message body.
struct ProtobufReader {
    private let buf: [UInt8]
    private var i: Int

    init(_ bytes: [UInt8]) {
        self.buf = bytes
        self.i = 0
    }

    var isAtEnd: Bool { i >= buf.count }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard i < buf.count else { throw StudioError.truncated }
            let byte = buf[i]; i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift < 64 else { throw StudioError.malformed("varint too long") }
        }
        return result
    }

    /// Next field's number and wire type.
    mutating func nextField() throws -> (field: Int, type: WireType) {
        let key = try varint()
        guard let type = WireType(rawValue: UInt8(key & 0x07)) else {
            throw StudioError.malformed("unknown wire type \(key & 0x07)")
        }
        return (Int(key >> 3), type)
    }

    mutating func bytesField() throws -> [UInt8] {
        let n = Int(try varint())
        guard i + n <= buf.count else { throw StudioError.truncated }
        defer { i += n }
        return Array(buf[i..<(i + n)])
    }

    mutating func stringField() throws -> String {
        String(decoding: try bytesField(), as: UTF8.self)
    }

    static func unzigzag(_ v: UInt64) -> Int32 {
        let u = UInt32(truncatingIfNeeded: v)
        return Int32(bitPattern: (u >> 1)) ^ -Int32(bitPattern: u & 1)
    }

    /// Advance past a field whose contents we don't care about.
    mutating func skip(_ type: WireType) throws {
        switch type {
        case .varint: _ = try varint()
        case .lengthDelimited: _ = try bytesField()
        case .fixed32: i += 4
        case .fixed64: i += 8
        }
        guard i <= buf.count else { throw StudioError.truncated }
    }
}

enum StudioError: Error, CustomStringConvertible {
    case truncated
    case malformed(String)
    case portUnavailable(String)
    case timeout(String)
    case locked
    case rpc(String)

    var description: String {
        switch self {
        case .truncated: return "message ended mid-field"
        case .malformed(let s): return "malformed message: \(s)"
        case .portUnavailable(let s): return "serial port unavailable: \(s)"
        case .timeout(let s): return "timed out waiting for \(s)"
        case .locked: return "keyboard is locked; press the &studio_unlock key"
        case .rpc(let s): return "RPC error: \(s)"
        }
    }
}
