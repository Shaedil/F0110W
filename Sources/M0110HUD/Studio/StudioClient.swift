import Foundation

/// Synchronous ZMK Studio RPC client over a CDC ACM serial port.
///
/// Envelope shapes come from `modules/msgs/zmk-studio-messages/proto/zmk/`:
/// requests are `zmk.studio.Request{request_id, oneof subsystem}` and responses
/// are `zmk.studio.Response{request_response|notification}`.
final class StudioClient {
    private let transport: StudioTransport
    private var nextRequestID: UInt32 = 1
    /// Set by the transport: a GATT link needs far longer than a serial port.
    private var timeout: TimeInterval { transport.responseTimeout }

    /// How this client is connected, for logs and for the UI.
    var label: String { transport.label }

    /// Response payload for one subsystem, still protobuf-encoded.
    private enum Subsystem: Int {
        case meta = 2, core = 3, behaviors = 4, keymap = 5
    }

    init(transport: StudioTransport) {
        self.transport = transport
    }

    convenience init(port: String) {
        self.init(transport: SerialTransport(path: port))
    }

    func open() throws { try transport.open() }
    func close() { transport.close() }

    // MARK: - Envelope

    private func send(subsystem: Subsystem, body: [UInt8]) throws -> (id: UInt32, payload: [UInt8]) {
        let id = nextRequestID
        nextRequestID += 1

        var w = ProtobufWriter()
        w.uint32(1, id, skipZero: false)
        w.message(subsystem.rawValue, body)
        try transport.send(w.bytes)

        // Notifications can interleave, so keep reading until our id comes back.
        // The transport's timeout means "this long without any data", so each
        // read gets the full allowance; the cap here only stops an endless
        // stream of notifications from pinning the caller forever.
        let deadline = Date().addingTimeInterval(timeout * 5)
        while Date() < deadline {
            let frame = try transport.receiveFrame(timeout: timeout)
            guard let response = try Self.parseResponse(frame) else { continue }  // notification
            guard response.id == id else { continue }
            // The firmware answers on the meta subsystem when it refuses a call,
            // most often because Studio is locked.
            if response.subsystem == Subsystem.meta.rawValue {
                throw Self.metaError(response.payload)
            }
            return (response.id, response.payload)
        }
        throw StudioError.timeout("response to request \(id)")
    }

    /// zmk.meta.Response{no_response = 1, simple_error = 2 ErrorConditions}
    private static func metaError(_ payload: [UInt8]) -> StudioError {
        var r = ProtobufReader(payload)
        while !r.isAtEnd {
            guard let (field, type) = try? r.nextField() else { break }
            if field == 2, type == .varint, let code = try? r.varint() {
                switch code {
                case 1: return .locked
                case 2: return .rpc("the firmware does not implement that call")
                case 3: return .rpc("the firmware could not decode the request")
                case 4: return .rpc("the firmware could not encode its reply")
                default: return .rpc("the firmware reported a generic error")
                }
            }
            if field == 1 { return .rpc("the firmware sent no response") }
            if (try? r.skip(type)) == nil { break }
        }
        return .rpc("the firmware refused the request")
    }

    /// Returns nil for notifications, which carry no request id. `subsystem` is
    /// the field number the reply arrived on, so meta errors can be told apart
    /// from a real subsystem payload.
    private static func parseResponse(_ frame: [UInt8]) throws -> (id: UInt32, subsystem: Int, payload: [UInt8])? {
        var r = ProtobufReader(frame)
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            switch (field, type) {
            case (1, .lengthDelimited):
                // RequestResponse{request_id=1, <subsystem payload>}
                var inner = ProtobufReader(try r.bytesField())
                var id: UInt32 = 0
                var payload: [UInt8] = []
                var subsystem = 0
                while !inner.isAtEnd {
                    let (f, t) = try inner.nextField()
                    if f == 1, t == .varint {
                        id = UInt32(truncatingIfNeeded: try inner.varint())
                    } else if t == .lengthDelimited {
                        subsystem = f
                        payload = try inner.bytesField()
                    } else {
                        try inner.skip(t)
                    }
                }
                return (id, subsystem, payload)
            case (2, .lengthDelimited):
                _ = try r.bytesField()   // notification; ignored
                return nil
            default:
                try r.skip(type)
            }
        }
        return nil
    }

    /// Unwrap a subsystem response to the payload of one expected field number.
    private static func field(_ number: Int, in payload: [UInt8]) throws -> ProtobufValue {
        var r = ProtobufReader(payload)
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            if field == number {
                switch type {
                case .lengthDelimited: return .bytes(try r.bytesField())
                case .varint: return .number(try r.varint())
                default: try r.skip(type)
                }
            } else {
                try r.skip(type)
            }
        }
        throw StudioError.rpc("response had no field \(number)")
    }

    enum ProtobufValue {
        case bytes([UInt8])
        case number(UInt64)

        var asBytes: [UInt8] { if case .bytes(let b) = self { return b } else { return [] } }
        var asNumber: UInt64 { if case .number(let n) = self { return n } else { return 0 } }
    }

    /// Generic entry point so other subsystems (behaviors) can reuse the envelope.
    func request(subsystem: Int, body: [UInt8]) throws -> [UInt8] {
        guard let sub = Subsystem(rawValue: subsystem) else {
            throw StudioError.rpc("unknown subsystem \(subsystem)")
        }
        return try send(subsystem: sub, body: body).payload
    }

    static func subfield(_ number: Int, in payload: [UInt8]) throws -> [UInt8] {
        try field(number, in: payload).asBytes
    }

    // MARK: - core

    func deviceInfo() throws -> DeviceInfo {
        var w = ProtobufWriter(); w.bool(1, true)
        let response = try send(subsystem: .core, body: w.bytes)
        return try DeviceInfo.decode(Self.field(1, in: response.payload).asBytes)
    }

    func lockState() throws -> LockState {
        var w = ProtobufWriter(); w.bool(2, true)
        let response = try send(subsystem: .core, body: w.bytes)
        let raw = try Self.field(2, in: response.payload).asNumber
        return LockState(rawValue: UInt32(truncatingIfNeeded: raw)) ?? .locked
    }

    // MARK: - keymap

    func keymap() throws -> Keymap {
        var w = ProtobufWriter(); w.bool(1, true)
        let response = try send(subsystem: .keymap, body: w.bytes)
        return try Keymap.decode(Self.field(1, in: response.payload).asBytes)
    }

    func physicalLayouts() throws -> PhysicalLayouts {
        var w = ProtobufWriter(); w.bool(6, true)
        let response = try send(subsystem: .keymap, body: w.bytes)
        return try PhysicalLayouts.decode(Self.field(6, in: response.payload).asBytes)
    }

    /// Writes one binding. The keyboard must be unlocked first (press the key
    /// bound to `&studio_unlock`), otherwise this reports a locked error.
    func setBinding(layerID: UInt32, keyPosition: Int32, binding: BehaviorBinding) throws {
        var request = ProtobufWriter()
        request.uint32(1, layerID)
        request.int32(2, keyPosition)
        request.message(3, binding.encoded)

        var w = ProtobufWriter()
        w.message(2, request.bytes)
        let response = try send(subsystem: .keymap, body: w.bytes)
        let code = try Self.field(2, in: response.payload).asNumber
        switch code {
        case 0: return
        case 1: throw StudioError.rpc("invalid key position \(keyPosition)")
        case 2: throw StudioError.rpc("invalid behavior \(binding.behaviorID)")
        case 3: throw StudioError.rpc("invalid parameters for behavior \(binding.behaviorID)")
        default: throw StudioError.rpc("set_layer_binding returned \(code)")
        }
    }

    func saveChanges() throws {
        var w = ProtobufWriter(); w.bool(4, true)
        let response = try send(subsystem: .keymap, body: w.bytes)
        // SaveChangesResponse{oneof ok=1(bool) | err=2(enum)}
        var r = ProtobufReader(try Self.field(4, in: response.payload).asBytes)
        while !r.isAtEnd {
            let (field, type) = try r.nextField()
            guard type == .varint else { try r.skip(type); continue }
            let v = try r.varint()
            if field == 1 { return }
            if field == 2 {
                let reason = ["ok", "generic failure", "not supported", "no space"]
                throw StudioError.rpc("save failed: \(reason[safe: Int(v)] ?? "code \(v)")")
            }
        }
    }

    func discardChanges() throws {
        var w = ProtobufWriter(); w.bool(5, true)
        _ = try send(subsystem: .keymap, body: w.bytes)
    }

    /// Find a keyboard that answers `get_device_info` over the Studio RPC
    /// protocol.
    ///
    /// Each CDC ACM port is tried first and Bluetooth second, on cost: probing
    /// a serial port is instant and local, while the Bluetooth route connects
    /// to the peripheral and negotiates a subscription before it can answer
    /// anything. ZMK exposes a logging console alongside the RPC endpoint, so
    /// the wrong port never replies.
    ///
    /// Only one of them can work at a time regardless, since the firmware binds
    /// its RPC to whichever endpoint the keyboard is currently outputting to,
    /// so the second is tried only when the first found nothing.
    static func discover(deviceName: String,
                         log: @escaping (String) -> Void = { _ in }) -> (client: StudioClient, info: DeviceInfo)? {
        var transports: [StudioTransport] = SerialTransport.candidatePorts().map {
            SerialTransport(path: $0)
        }
        transports.append(BLETransport(deviceName: deviceName, log: log))

        for transport in transports {
            let client = StudioClient(transport: transport)
            do {
                try client.open()
                let info = try client.deviceInfo()
                log("studio: \(transport.label) responded: \(info.name)")
                return (client, info)
            } catch {
                log("studio: \(transport.label): \(error)")
                client.close()
            }
        }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
