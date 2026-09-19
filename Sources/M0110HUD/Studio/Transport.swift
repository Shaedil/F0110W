import Foundation

/// Byte framing used by ZMK Studio's RPC transports, mirroring
/// `zmk/app/src/studio/msg_framing.h`: a frame runs from SOF to EOF, and any
/// payload byte that collides with a framing byte is escaped.
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

    /// Incremental unescaping. Feed bytes as they arrive; a completed frame is
    /// returned once, on the byte that closes it.
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
                // A fresh SOF abandons any partial frame.
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

/// A blocking byte channel carrying framed Studio RPC messages.
///
/// `StudioClient` is synchronous and runs on its own serial queue, so a
/// transport's job is to make whatever it wraps look blocking, whether that is
/// the CDC ACM serial port or the firmware's GATT service.
protocol StudioTransport: AnyObject {
    /// How the connection is described in logs and in the UI.
    var label: String { get }
    var isOpen: Bool { get }
    /// How long one request may take to answer, end to end.
    var responseTimeout: TimeInterval { get }

    func open() throws
    func close()
    func send(_ payload: [UInt8]) throws
    /// Block until a complete frame arrives or `timeout` elapses.
    func receiveFrame(timeout: TimeInterval) throws -> [UInt8]
}

/// Blocking serial transport over a CDC ACM port.
///
/// ZMK exposes two CDC ACM interfaces on this build, a logging console and the
/// Studio RPC endpoint, so callers generally probe each candidate port.
final class SerialTransport: StudioTransport {
    private var fd: Int32 = -1
    private let path: String
    private var decoder = StudioFraming.Decoder()

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
        // O_NONBLOCK so opening doesn't block on carrier detect; cleared after.
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
        // Back to blocking reads; VMIN/VTIME now govern timing.
        _ = fcntl(fd, F_SETFL, 0)
        tcflush(fd, TCIOFLUSH)
        decoder = StudioFraming.Decoder()
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

    /// Read until a complete frame arrives or `timeout` elapses.
    func receiveFrame(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        var scratch = [UInt8](repeating: 0, count: 512)
        while Date() < deadline {
            let n = scratch.withUnsafeMutableBufferPointer {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw StudioError.portUnavailable("\(path): read failed")
            }
            for i in 0..<n {
                if let frame = decoder.feed(scratch[i]) { return frame }
            }
        }
        throw StudioError.timeout("a response frame on \(path)")
    }
}
