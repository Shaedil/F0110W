import CM0110Win
import Foundation

/// Blocking serial transport over a CDC ACM port: the Windows side of
/// Studio/Transport.swift's, with COM ports in place of /dev/cu.usbmodem*.
final class SerialTransport: StudioTransport {
    private var port: UnsafeMutableRawPointer?
    private let path: String
    private var decoder = StudioFraming.Decoder()
    /// Frames decoded but not yet handed out; see the Mac transport.
    private var pending: [[UInt8]] = []

    var label: String { path }
    let responseTimeout: TimeInterval = 3

    init(path: String) {
        self.path = path
    }

    deinit { close() }

    /// Every USB CDC ACM port, in COM number order.
    static func candidatePorts() -> [String] {
        var buffer = [UInt16](repeating: 0, count: 4096)
        guard m0110_serial_ports(&buffer, UInt32(buffer.count)) > 0 else { return [] }
        return buffer.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF16.self) }
    }

    func open() throws {
        var error: UInt32 = 0
        guard let handle = m0110_serial_open(path.wide, &error) else {
            throw StudioError.portUnavailable("\(path): error \(error)")
        }
        port = handle
        decoder = StudioFraming.Decoder()
        pending.removeAll()
    }

    func close() {
        if let port { m0110_serial_close(port) }
        port = nil
    }

    var isOpen: Bool { port != nil }

    func send(_ payload: [UInt8]) throws {
        guard let port else { throw StudioError.portUnavailable("\(path): not open") }
        let framed = StudioFraming.wrap(payload)
        guard m0110_serial_write(port, framed, UInt32(framed.count)) == Int32(framed.count) else {
            throw StudioError.portUnavailable("\(path): write failed")
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

    /// One read, waiting at most 100 ms, with every frame it completes queued.
    private func readOnce() throws {
        guard let port else { throw StudioError.portUnavailable("\(path): not open") }
        var scratch = [UInt8](repeating: 0, count: 512)
        let n = m0110_serial_read(port, &scratch, UInt32(scratch.count))
        guard n >= 0 else { throw StudioError.portUnavailable("\(path): read failed") }
        for i in 0..<Int(n) {
            if let frame = decoder.feed(scratch[i]) { pending.append(frame) }
        }
    }
}
