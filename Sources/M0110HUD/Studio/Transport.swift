import Foundation

/// Studio RPC byte framing, matching `zmk/app/src/studio/msg_framing.h`. A frame
/// runs from SOF to EOF, and payload bytes equal to a framing byte are escaped.
enum StudioFraming {
    static let sof: UInt8 = 0xAB
    static let esc: UInt8 = 0xAC
    static let eof: UInt8 = 0xAD

    static func wrap(_ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [sof]
        for byte in payload {
            if byte == sof || byte == esc || byte == eof { out.append(esc) }
            out.append(byte)
        }
        out.append(eof)
        return out
    }

    /// Incremental unescaping. Returns each completed frame once, on its closing byte.
    struct Decoder {
        private var payload = [UInt8]()
        private var inFrame = false
        private var escaped = false

        mutating func feed(_ byte: UInt8) -> [UInt8]? {
            if escaped {
                payload.append(byte)
                escaped = false
                return nil
            }
            switch byte {
            case StudioFraming.sof:
                // A new SOF drops any partial frame.
                payload.removeAll()
                inFrame = true
            case StudioFraming.esc where inFrame:
                escaped = true
            case StudioFraming.eof where inFrame:
                inFrame = false
                let done = payload
                payload.removeAll()
                return done
            default:
                if inFrame { payload.append(byte) }
            }
            return nil
        }
    }
}

/// Blocking byte channel for framed Studio RPC messages. `StudioClient` is
/// synchronous, so each transport makes its link (serial or GATT) look blocking.
protocol StudioTransport: AnyObject {
    var label: String { get }
    var isOpen: Bool { get }
    var responseTimeout: TimeInterval { get }

    func open() throws
    func close()
    func send(_ payload: [UInt8]) throws
    func receiveFrame(timeout: TimeInterval) throws -> [UInt8]
    /// A frame that already arrived, or nil, without waiting. Used to read
    /// notifications while no request is running.
    func receiveFrameIfAvailable() throws -> [UInt8]?
}

#if canImport(Darwin)
/// Blocking serial transport over a CDC ACM port (Windows version: Windows/SerialTransport.swift).
/// ZMK exposes two CDC ACM ports here, a log console and Studio RPC, so callers probe each one.
final class SerialTransport: StudioTransport {
    private var fd: Int32 = -1
    private let path: String
    private var decoder = StudioFraming.Decoder()
    /// Decoded frames not yet returned. One read can hold several, since the firmware
    /// sends a notification right before the reply to the request that caused it.
    private var pending: [[UInt8]] = []

    var label: String { path }
    let responseTimeout: TimeInterval = 3

    init(path: String) {
        self.path = path
    }

    deinit { close() }

    static func candidatePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.usbmodem") }
            .sorted()
            .map { "/dev/\($0)" }
    }

    func open() throws {
        // O_NONBLOCK so open does not wait for carrier detect. Cleared below.
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw StudioError.portUnavailable("\(path): \(String(cString: strerror(errno)))") }

        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            close()
            throw StudioError.portUnavailable("\(path): tcgetattr failed")
        }
        cfmakeraw(&settings)
        settings.c_cc.16 = 0   // VMIN:  don't block for a minimum byte count
        settings.c_cc.17 = 1   // VTIME: 0.1s read timeout
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            close()
            throw StudioError.portUnavailable("\(path): tcsetattr failed")
        }
        // Back to blocking reads. VMIN/VTIME now control timing.
        _ = fcntl(fd, F_SETFL, 0)
        tcflush(fd, TCIOFLUSH)
        decoder = StudioFraming.Decoder()
        pending.removeAll()
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    var isOpen: Bool { fd >= 0 }

    func send(_ payload: [UInt8]) throws {
        let framed = StudioFraming.wrap(payload)
        var written = 0
        while written < framed.count {
            let n = framed[written...].withUnsafeBufferPointer {
                Darwin.write(fd, $0.baseAddress, $0.count)
            }
            guard n > 0 else { throw StudioError.portUnavailable("\(path): write failed") }
            written += n
        }
    }

    func receiveFrame(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while pending.isEmpty, Date() < deadline {
            try readOnce()
        }
        guard !pending.isEmpty else { throw StudioError.timeout("a response frame on \(path)") }
        return pending.removeFirst()
    }

    func receiveFrameIfAvailable() throws -> [UInt8]? {
        if pending.isEmpty { try readOnce() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Does one read, waiting at most VTIME, and queues every frame it completes.
    private func readOnce() throws {
        var scratch = [UInt8](repeating: 0, count: 512)
        let n = scratch.withUnsafeMutableBufferPointer {
            Darwin.read(fd, $0.baseAddress, $0.count)
        }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            throw StudioError.portUnavailable("\(path): read failed")
        }
        for i in 0..<n {
            if let frame = decoder.feed(scratch[i]) { pending.append(frame) }
        }
    }
}
#endif
