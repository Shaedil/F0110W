import CryptoKit
import XCTest

@testable import M0110HUD

/// Tests the Mac side against the Python helper over a real socket. Needs `uv` and
/// network access, so run it with `M0110_INTEROP=1 swift test --filter Interop`.
final class ClipInteropTests: XCTestCase {
    private let id: [UInt8] = Array(0x50...0x57)
    private let key: [UInt8] = (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
    /// Enough for three records, so record numbering gets tested too.
    private let content = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })

    private let loopback = ClipAddress([127, 0, 0, 1])!

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["M0110_INTEROP"] == "1",
                          "set M0110_INTEROP=1 to run against the Python helper")
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(_ data: Data) -> String {
        hex(Array(SHA256.hash(data: data)))
    }

    private final class Helper {
        let process = Process()
        private let pipe = Pipe()
        private var buffer = Data()
        private(set) var lines: [String] = []

        init(repository: URL, arguments: [String]) throws {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "uv", "run", "--quiet", "--with", "bleak", "--with", "cryptography", "--with",
                "pillow", "python3", "-u", "helper/test_m0110_clipboard.py",
            ] + arguments
            process.currentDirectoryURL = repository
            process.standardOutput = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.buffer.append(data)
                    while let newline = self.buffer.firstIndex(of: 0x0A) {
                        let line = self.buffer[self.buffer.startIndex..<newline]
                        self.lines.append(String(decoding: line, as: UTF8.self))
                        self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    }
                }
            }
            try process.run()
        }

        deinit {
            pipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 60, file: StaticString = #filePath,
                         line: UInt = #line, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)", file: file, line: line)
    }

    private func channel() -> ClipChannel {
        let channel = ClipChannel()
        channel.start()
        waitFor("the listener") { channel.port != nil }
        addTeardownBlock { channel.stop() }
        return channel
    }

    private func contentFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m0110-interop-\(UUID().uuidString)")
        try content.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMacFetchesFromTheHelper() throws {
        let helper = try Helper(repository: repository,
                                arguments: ["interop-serve", "2", try contentFile().path])
        waitFor("the helper to listen") { !helper.lines.isEmpty }
        let fields = helper.lines[0].split(separator: " ").map(String.init)
        XCTAssertEqual(fields.count, 3)

        let port = try XCTUnwrap(UInt16(fields[0]))
        let theirID = stride(from: 0, to: fields[1].count, by: 2).map { offset -> UInt8 in
            let start = fields[1].index(fields[1].startIndex, offsetBy: offset)
            return UInt8(fields[1][start..<fields[1].index(start, offsetBy: 2)], radix: 16)!
        }
        let theirKey = stride(from: 0, to: fields[2].count, by: 2).map { offset -> UInt8 in
            let start = fields[2].index(fields[2].startIndex, offsetBy: offset)
            return UInt8(fields[2][start..<fields[2].index(start, offsetBy: 2)], radix: 16)!
        }

        var fetched: Data??
        channel().fetch(id: theirID, key: theirKey, from: [loopback], port: port) { fetched = $0 }
        waitFor("the fetch") { fetched != nil }
        XCTAssertEqual(fetched, content)
    }

    func testHelperFetchesFromTheMac() throws {
        let source = channel()
        source.offering = (id, key, { [content] in content })

        let helper = try Helper(repository: repository, arguments: [
            "interop-get", "127.0.0.1", String(source.port!), hex(id), hex(key),
        ])
        waitFor("the helper's fetch") { !helper.lines.isEmpty }
        XCTAssertEqual(helper.lines.first, "- \(sha256(content)) \(content.count)")
    }

    func testHelperHandsOverToTheMac() throws {
        let receiver = channel()
        var received: Data?
        receiver.expecting = (id, key, { received = $0 })

        let helper = try Helper(repository: repository, arguments: [
            "interop-put", "127.0.0.1", String(receiver.port!), hex(id), hex(key),
            try contentFile().path,
        ])
        waitFor("the helper's push") { received != nil }
        XCTAssertEqual(received, content)
        waitFor("the helper to finish") { !helper.process.isRunning }
        XCTAssertEqual(helper.process.terminationStatus, 0)
    }

    func testMacHandsOverToTheHelper() throws {
        let helper = try Helper(repository: repository,
                                arguments: ["interop-accept", hex(id), hex(key)])
        waitFor("the helper to listen") { !helper.lines.isEmpty }
        let port = try XCTUnwrap(UInt16(helper.lines[0]))

        var handedOver: Bool?
        channel().push(id: id, key: key, content: content, to: [loopback], port: port) {
            handedOver = $0
        }
        waitFor("the push") { handedOver != nil && helper.lines.count >= 2 }
        XCTAssertEqual(handedOver, true)
        XCTAssertEqual(helper.lines.last, "\(sha256(content)) \(content.count)")
    }
}
