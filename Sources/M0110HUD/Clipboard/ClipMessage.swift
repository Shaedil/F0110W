import Foundation

/// What the helpers pass each other when the keyboard cannot carry the content
/// itself: an image, or text longer than it holds.
///
/// `helper/PROTOCOL.md` is the reference for all of it. The keyboard carries a
/// `ClipMessage` as an opaque clip and a `ClipDatagram` as a RELAY, and looks
/// inside neither.
struct ClipContent: Equatable {
    enum Kind: UInt8 {
        /// UTF-8, LF line endings.
        case text = 1
        case png = 2
        case jpeg = 3
    }

    let kind: Kind
    let data: Data
}

/// One of a computer's own network addresses: 4 bytes of IPv4 or 16 of IPv6.
struct ClipAddress: Equatable {
    let bytes: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    var isIPv4: Bool { bytes.count == 4 }

    fileprivate var encoded: [UInt8] { [isIPv4 ? 4 : 6] + bytes }

    /// Encodes as many of `addresses` as fit in `room` bytes, count first.
    fileprivate static func encode(_ addresses: [ClipAddress], room: Int) -> [UInt8] {
        var out: [UInt8] = [0]
        for address in addresses.prefix(ClipMessage.maxAddresses) {
            let next = address.encoded
            guard out.count + next.count <= room else { break }
            out += next
            out[0] += 1
        }
        return out
    }

    /// Decodes a counted list starting at `index`, or nil if it is cut short.
    fileprivate static func decode(_ bytes: [UInt8], at index: Int) -> [ClipAddress]? {
        guard index < bytes.count else { return nil }
        var addresses: [ClipAddress] = []
        var cursor = index + 1

        for _ in 0..<Int(bytes[index]) {
            guard cursor < bytes.count else { return nil }
            let length: Int
            switch bytes[cursor] {
            case 4: length = 4
            case 6: length = 16
            default: return nil
            }
            guard cursor + 1 + length <= bytes.count,
                  let address = ClipAddress(Array(bytes[(cursor + 1)..<(cursor + 1 + length)]))
            else { return nil }
            addresses.append(address)
            cursor += 1 + length
        }
        return addresses
    }
}

/// The inside of an opaque clip.
enum ClipMessage: Equatable {
    static let idLength = 8
    static let keyLength = 32
    static let maxAddresses = 6
    /// The bytes of an INLINE that are not content.
    static let inlineOverhead = 2 + idLength

    /// "The content is here; come and fetch it."
    case offer(kind: ClipContent.Kind, id: [UInt8], key: [UInt8], port: UInt16,
               addresses: [ClipAddress])
    /// The content itself, cut down to fit through the keyboard.
    case inline(kind: ClipContent.Kind, id: [UInt8], content: [UInt8])

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= ClipMessage.inlineOverhead,
              let kind = ClipContent.Kind(rawValue: bytes[1]) else { return nil }
        let id = Array(bytes[2..<(2 + ClipMessage.idLength)])

        switch bytes[0] {
        case 1:
            let keyEnd = 2 + ClipMessage.idLength + ClipMessage.keyLength
            guard bytes.count >= keyEnd + 3,
                  let addresses = ClipAddress.decode(bytes, at: keyEnd + 2) else { return nil }
            self = .offer(kind: kind, id: id,
                          key: Array(bytes[(2 + ClipMessage.idLength)..<keyEnd]),
                          port: ClipWire.readLE16(bytes, at: keyEnd), addresses: addresses)
        case 2:
            self = .inline(kind: kind, id: id,
                           content: Array(bytes[ClipMessage.inlineOverhead...]))
        default:
            return nil
        }
    }

    var encoded: [UInt8] {
        switch self {
        case let .offer(kind, id, key, port, addresses):
            return [1, kind.rawValue] + id + key + ClipWire.le16(port)
                + ClipAddress.encode(addresses, room: .max)
        case let .inline(kind, id, content):
            return [2, kind.rawValue] + id + content
        }
    }
}

/// The inside of a RELAY: a word from one helper to the other, not stored.
enum ClipDatagram: Equatable {
    /// "I could not reach you. Reach me here, or send it through the keyboard."
    case want(id: [UInt8], port: UInt16, addresses: [ClipAddress])
    /// "That copy cannot be had."
    case gone(id: [UInt8])
    /// "I no longer want that copy; do not send it."
    case cancel(id: [UInt8])

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 1 + ClipMessage.idLength else { return nil }
        let id = Array(bytes[1..<(1 + ClipMessage.idLength)])

        switch bytes[0] {
        case 1:
            let portAt = 1 + ClipMessage.idLength
            guard bytes.count >= portAt + 3,
                  let addresses = ClipAddress.decode(bytes, at: portAt + 2) else { return nil }
            self = .want(id: id, port: ClipWire.readLE16(bytes, at: portAt), addresses: addresses)
        case 2:
            self = .gone(id: id)
        case 3:
            self = .cancel(id: id)
        default:
            return nil
        }
    }

    /// The datagram in at most `room` bytes, leaving out addresses that do not
    /// fit. A WANT with none still fits any link.
    func encoded(room: Int) -> [UInt8] {
        switch self {
        case let .want(id, port, addresses):
            let head = [1] + id + ClipWire.le16(port)
            return head + ClipAddress.encode(addresses, room: room - head.count)
        case let .gone(id):
            return [2] + id
        case let .cancel(id):
            return [3] + id
        }
    }
}
