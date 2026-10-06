import Foundation

/// The wire format of the keyboard's clipboard service.
///
/// Mirrors `config/clipboard/clip_proto.h` in the firmware: one frame per GATT
/// write or notification, the first byte the frame type, multi-byte fields
/// little-endian. A clip travels the same way in both directions, as BEGIN,
/// then DATA frames in offset order, then END.
///
/// A clip is text, or it is opaque: a message for the helper on another
/// computer, which the keyboard carries and never types. `ClipMessage` is what
/// goes inside one.
enum ClipWire {
    static let version: UInt8 = 2

    enum Frame: UInt8 {
        case begin = 0x01
        case data = 0x02
        case end = 0x03
        case clear = 0x04
        case hello = 0x05
        case ack = 0x06
        case bye = 0x07
        case relay = 0x08
        case hold = 0x09
        case status = 0x10
        case result = 0x11
        case poke = 0x12
    }

    /// BEGIN flags. Without `usbKnown` the keyboard cannot tell whether its USB
    /// port leads back to this computer, and leaves pastes over USB alone.
    static let usbKnown: UInt8 = 0x01
    static let usbLocal: UInt8 = 0x02
    /// BEGIN flag, either direction: the clip is opaque rather than text.
    static let opaque: UInt8 = 0x04

    /// HOLD flags. With `holdSoon` a paste waits for the fetch; without, it is
    /// dropped. `holdOff` ends the hold.
    static let holdSoon: UInt8 = 0x01
    static let holdOff: UInt8 = 0x02
    /// A hold lapses unless repeated at least this often.
    static let holdRepeat: TimeInterval = 0.4

    /// The longest RELAY frame the keyboard passes on, type byte included.
    static let relayMax = 64
    /// RESULT code for a RELAY that had no helper to go to.
    static let resultUnreachable: UInt8 = 3

    static let dataHeaderLength = 3

    /// CRC-32 (IEEE 802.3), bitwise to match the firmware's.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }

    static let end = Data([Frame.end.rawValue])
    static let clear = Data([Frame.clear.rawValue])
    static let bye = Data([Frame.bye.rawValue])
    static let hello = Data([Frame.hello.rawValue, version, 0])

    static func ack(crc: UInt32) -> Data {
        Data([Frame.ack.rawValue] + le32(crc))
    }

    static func hold(_ flags: UInt8) -> Data {
        Data([Frame.hold.rawValue, flags])
    }

    static func relay(_ datagram: [UInt8]) -> Data {
        Data([Frame.relay.rawValue] + datagram)
    }

    /// Every frame needed to send `payload`, sized for a link that takes
    /// `frameCap` bytes per write.
    static func transfer(_ payload: [UInt8], flags: UInt8, frameCap: Int) -> [Data] {
        let length = UInt16(payload.count)
        var frames = [Data([Frame.begin.rawValue, flags] + le16(length) + le32(crc32(payload)))]

        let room = max(1, frameCap - dataHeaderLength)
        var offset = 0
        while offset < payload.count {
            let next = min(offset + room, payload.count)
            let header = [Frame.data.rawValue] + le16(UInt16(offset))
            frames.append(Data(header + Array(payload[offset..<next])))
            offset = next
        }

        frames.append(end)
        return frames
    }

    static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    static func readLE16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    static func readLE32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[index + $1]) << (8 * $1) }
    }
}

/// Reassembles a clip the keyboard is delivering.
///
/// DATA must arrive in order. A gap, an overrun or a checksum mismatch fails
/// the whole clip at END rather than yielding part of one.
struct ClipAssembler {
    /// As long as the wire format can say; a bound on what a misbehaving
    /// peripheral can make this app buffer.
    static let maxLength = 65535

    private var expected = 0
    private var crc: UInt32 = 0
    private var flags: UInt8 = 0
    private var bytes: [UInt8] = []
    private(set) var active = false
    private var poisoned = false

    mutating func begin(_ frame: [UInt8]) {
        active = false
        guard frame.count >= 8 else { return }
        let length = Int(ClipWire.readLE16(frame, at: 2))
        guard length > 0, length <= Self.maxLength else { return }

        expected = length
        flags = frame[1]
        crc = ClipWire.readLE32(frame, at: 4)
        bytes = []
        bytes.reserveCapacity(length)
        poisoned = false
        active = true
    }

    mutating func data(_ frame: [UInt8]) {
        guard active, frame.count >= ClipWire.dataHeaderLength else { return }
        let offset = Int(ClipWire.readLE16(frame, at: 1))
        let payload = frame[ClipWire.dataHeaderLength...]

        guard offset == bytes.count, payload.count <= expected - bytes.count else {
            poisoned = true
            return
        }
        bytes.append(contentsOf: payload)
    }

    /// The verified clip, its checksum and whether it is opaque, or nil if
    /// the transfer was bad.
    mutating func end() -> (bytes: [UInt8], crc: UInt32, opaque: Bool)? {
        defer {
            active = false
            bytes = []
        }
        guard active, !poisoned, bytes.count == expected, ClipWire.crc32(bytes) == crc else {
            return nil
        }
        return (bytes, crc, flags & ClipWire.opaque != 0)
    }
}

/// Frames waiting to be written to the keyboard.
///
/// The frames of a clip go out in order, after everything else. An
/// acknowledgement or a hold queued behind a long upload would reach the
/// keyboard after the paste it was meant for, so anything that is not part of
/// a clip goes ahead of one. Each frame stands on its own, and the keyboard
/// does not mind one arriving in the middle of a clip.
struct ClipOutbox {
    private var control: [Data] = []
    private var clip: [Data] = []

    var isEmpty: Bool { control.isEmpty && clip.isEmpty }

    /// Queues a frame that is not part of a clip.
    mutating func send(_ frame: Data) {
        control.append(frame)
    }

    /// Queues a clip, in place of whatever is left of the one before it.
    mutating func sendClip(_ frames: [Data]) {
        clip = frames
    }

    /// Drops whatever is left of the clip being sent.
    mutating func dropClip() {
        clip.removeAll()
    }

    mutating func removeAll() {
        control.removeAll()
        clip.removeAll()
    }

    /// The next frame to write.
    mutating func next() -> Data? {
        if !control.isEmpty { return control.removeFirst() }
        return clip.isEmpty ? nil : clip.removeFirst()
    }
}
