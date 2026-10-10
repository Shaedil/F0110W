import CryptoKit
import Foundation
import Network

/// Encrypted record stream between helpers (see "The stream" in `helper/PROTOCOL.md`).
/// Each record is `last:u8 n:u32 sealed[n]`, sealed with ChaCha20-Poly1305 under
/// the copy's one-time key. The nonce is the record number and `last` is
/// authenticated, so reordered, replayed or cut-off records fail to open.
enum ClipStream {
    static let chunk = 65536
    static let tagLength = 16
    static let headerLength = 5
    /// Bigger content is refused so a peer cannot make the app buffer without limit.
    static let maxContent = 256 << 20
    /// Sent back after the final record opens. A plain close does not prove delivery.
    static let taken: UInt8 = 1

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes += (0..<8).map { UInt8((counter >> (8 * UInt64($0))) & 0xFF) }
        // Nonce(data:) only accepts 12 bytes, so this cannot throw.
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func seal(_ content: Data, id: [UInt8], key: [UInt8]) -> Data {
        let key = SymmetricKey(data: key)
        var out = Data()
        var offset = 0
        var counter: UInt64 = 0

        repeat {
            let end = min(offset + chunk, content.count)
            let last: UInt8 = end == content.count ? 1 : 0
            let piece = content.subdata(in: (content.startIndex + offset)..<(content.startIndex + end))
            // Sealing only fails for a bad key or nonce, and both are made here.
            let box = try! ChaChaPoly.seal(piece, using: key, nonce: nonce(counter),
                                           authenticating: id + [last])
            let sealed = box.ciphertext + box.tag

            out.append(last)
            out.append(contentsOf: ClipWire.le32(UInt32(sealed.count)))
            out.append(sealed)
            offset = end
            counter += 1
        } while offset < content.count

        return out
    }

    struct Opener {
        private let key: SymmetricKey
        private let id: [UInt8]
        private let limit: Int
        private var counter: UInt64 = 0
        private(set) var content = Data()

        init(id: [UInt8], key: [UInt8], limit: Int = ClipStream.maxContent) {
            self.id = id
            self.key = SymmetricKey(data: key)
            self.limit = limit
        }

        /// Sealed length from a record header, or nil if the header is invalid.
        static func sealedLength(header: Data) -> Int? {
            let bytes = [UInt8](header)
            guard bytes.count == headerLength, bytes[0] <= 1 else { return nil }
            let length = Int(ClipWire.readLE32(bytes, at: 1))
            return (tagLength...(chunk + tagLength)).contains(length) ? length : nil
        }

        mutating func open(last: UInt8, sealed: Data) -> Bool {
            guard sealed.count >= tagLength,
                  content.count + sealed.count - tagLength <= limit,
                  let box = try? ChaChaPoly.SealedBox(
                      nonce: nonce(counter),
                      ciphertext: sealed.prefix(sealed.count - tagLength),
                      tag: sealed.suffix(tagLength)),
                  let piece = try? ChaChaPoly.open(box, using: key, authenticating: id + [last])
            else { return false }

            content.append(piece)
            counter += 1
            return true
        }
    }
}

/// Network transfer between helpers: one listening port, plus outgoing
/// connections. The side that connects names the copy and the direction, so
/// either side can accept, which helps when one is behind a firewall that
/// only allows outgoing connections. Runs on the main queue.
final class ClipChannel {
    private static let magic: [UInt8] = Array("M0CB".utf8) + [1]
    private static let helloLength = magic.count + 1 + ClipMessage.idLength
    private static let roleGet: UInt8 = 1
    private static let rolePut: UInt8 = 2

    /// Time a connection attempt gets before the next route is tried.
    static let connectTimeout: TimeInterval = 1
    var helloTimeout: TimeInterval = 5
    /// A stream with no progress for this long is dropped, so a hung peer or
    /// a silently dropped network cannot hold it open forever.
    var idleTimeout: TimeInterval = 10
    var maxContent = ClipStream.maxContent
    /// Bytes per send. The idle timer resets after each one.
    private static let writePiece = 256 << 10

    private let log: (String) -> Void
    private var listener: NWListener?

    private(set) var port: UInt16?

    /// The offered copy. `content` is only called when someone asks for it.
    var offering: (id: [UInt8], key: [UInt8], content: () -> Data?)?

    /// The copy this computer is waiting to be sent.
    var expecting: (id: [UInt8], key: [UInt8], received: (Data) -> Void)?

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                case .failed(let error):
                    self.log("clipboard: cannot listen for other helpers (\(error))")
                    self.port = nil
                    self.listener = nil
                    listener.cancel()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log("clipboard: cannot listen for other helpers (\(error))")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        offering = nil
        expecting = nil
    }

    // MARK: - Connecting out

    /// The connections of one attempt, so it can be cancelled while connecting or mid-stream.
    private final class Attempt {
        var connections: [NWConnection] = []
        var over = false

        func callOff() {
            over = true
            connections.forEach { $0.cancel() }
        }
    }

    /// Fetches copy `id` from the first of `addresses` that answers.
    /// `completion` gets nil on timeout or stream failure. The returned
    /// closure cancels the attempt, after which `completion` is not called.
    @discardableResult
    func fetch(id: [UInt8], key: [UInt8], from addresses: [ClipAddress], port: UInt16,
               completion: @escaping (Data?) -> Void) -> () -> Void {
        let attempt = Attempt()

        connect(attempt, to: addresses, port: port) { [idleTimeout, maxContent] connection in
            guard let connection else {
                completion(nil)
                return
            }
            connection.send(content: Data(Self.magic + [Self.roleGet] + id),
                            completion: .contentProcessed { _ in })
            Self.readStream(connection, id: id, key: key, idle: idleTimeout,
                            limit: maxContent) { content in
                if !attempt.over { completion(content) }
            }
        }
        return attempt.callOff
    }

    /// Sends copy `id` to the first address that answers. `completion` says if it took it all.
    @discardableResult
    func push(id: [UInt8], key: [UInt8], content: Data, to addresses: [ClipAddress], port: UInt16,
              completion: @escaping (Bool) -> Void) -> () -> Void {
        let attempt = Attempt()

        connect(attempt, to: addresses, port: port) { [idleTimeout] connection in
            guard let connection else {
                completion(false)
                return
            }
            let stream = Data(Self.magic + [Self.rolePut] + id)
                + ClipStream.seal(content, id: id, key: key)
            Self.writeStream(connection, stream, idle: idleTimeout) { taken in
                if !attempt.over { completion(taken) }
            }
        }
        return attempt.callOff
    }

    /// Tries every address at once. Returns the first to connect, or nil after `connectTimeout`.
    private func connect(_ attempt: Attempt, to addresses: [ClipAddress], port: UInt16,
                         completion: @escaping (NWConnection?) -> Void) {
        var settled = false

        func settle(_ winner: NWConnection?) {
            guard !settled else { return }
            settled = true
            for connection in attempt.connections where connection !== winner {
                connection.cancel()
            }
            attempt.connections = winner.map { [$0] } ?? []
            if !attempt.over { completion(winner) }
        }

        guard let port = NWEndpoint.Port(rawValue: port), !addresses.isEmpty else {
            DispatchQueue.main.async { settle(nil) }
            return
        }

        for address in addresses {
            let host: NWEndpoint.Host
            if address.isIPv4, let ip = IPv4Address(Data(address.bytes)) {
                host = .ipv4(ip)
            } else if let ip = IPv6Address(Data(address.bytes)) {
                host = .ipv6(ip)
            } else {
                continue
            }

            let connection = NWConnection(host: host, port: port, using: .tcp)
            connection.stateUpdateHandler = { [weak connection] state in
                guard let connection else { return }
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    if settled || attempt.over {
                        connection.cancel()
                    } else {
                        settle(connection)
                    }
                case .failed, .waiting:
                    // .waiting means no route for now. Treat it as a failure.
                    connection.cancel()
                default:
                    break
                }
            }
            attempt.connections.append(connection)
            connection.start(queue: .main)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) {
            settle(nil)
        }
    }

    // MARK: - Being connected to

    private func accept(_ connection: NWConnection) {
        var answered = false

        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + helloTimeout) {
            if !answered { connection.cancel() }
        }

        Self.read(connection, Self.helloLength) { [weak self] hello in
            answered = true
            guard let self, let hello, hello.starts(with: Self.magic) else {
                connection.cancel()
                return
            }
            let bytes = [UInt8](hello)
            let role = bytes[Self.magic.count]
            let id = Array(bytes[(Self.magic.count + 1)...])

            switch role {
            case Self.roleGet:
                guard let offering = self.offering, offering.id == id,
                      let content = offering.content() else {
                    connection.cancel()
                    return
                }
                let stream = ClipStream.seal(content, id: id, key: offering.key)
                Self.writeStream(connection, stream, idle: self.idleTimeout) { _ in }

            case Self.rolePut:
                guard let expecting = self.expecting, expecting.id == id else {
                    connection.cancel()
                    return
                }
                Self.readStream(connection, id: id, key: expecting.key, idle: self.idleTimeout,
                                limit: self.maxContent) { [weak self] content in
                    // Check it is still the expected copy and nothing else delivered it first.
                    guard let content, let now = self?.expecting, now.id == id else { return }
                    now.received(content)
                }

            default:
                connection.cancel()
            }
        }
    }

    // MARK: - Streams

    private static func read(_ connection: NWConnection, _ count: Int,
                             then: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) {
            data, _, _, error in
            guard error == nil, let data, data.count == count else {
                then(nil)
                return
            }
            then(data)
        }
    }

    /// Calls `expired` if `arm` is not called again within `idle`.
    private final class Watchdog {
        private let idle: TimeInterval
        private let expired: () -> Void
        private var pending: DispatchWorkItem?

        init(idle: TimeInterval, expired: @escaping () -> Void) {
            self.idle = idle
            self.expired = expired
        }

        func arm() {
            pending?.cancel()
            let item = DispatchWorkItem { [expired] in expired() }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + idle, execute: item)
        }

        func stop() {
            pending?.cancel()
            pending = nil
        }
    }

    /// Reads records up to the final one, sends the taken byte, and closes.
    /// `completion` gets nil if the stream was cut short, stalled, or a record did not open.
    private static func readStream(_ connection: NWConnection, id: [UInt8], key: [UInt8],
                                   idle: TimeInterval, limit: Int,
                                   completion: @escaping (Data?) -> Void) {
        var opener = ClipStream.Opener(id: id, key: key, limit: limit)
        var finished = false
        var watchdog: Watchdog?

        func finish(_ content: Data?) {
            guard !finished else { return }
            finished = true
            watchdog?.stop()

            if content != nil {
                connection.send(content: Data([ClipStream.taken]), contentContext: .finalMessage,
                                isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            } else {
                connection.cancel()
            }
            completion(content)
        }

        watchdog = Watchdog(idle: idle) { finish(nil) }

        func next() {
            watchdog?.arm()
            read(connection, ClipStream.headerLength) { header in
                guard let header, let length = ClipStream.Opener.sealedLength(header: header)
                else {
                    finish(nil)
                    return
                }
                let last = header[header.startIndex]

                read(connection, length) { sealed in
                    guard let sealed, opener.open(last: last, sealed: sealed) else {
                        finish(nil)
                        return
                    }
                    if last == 1 {
                        finish(opener.content)
                    } else {
                        next()
                    }
                }
            }
        }
        next()
    }

    /// Writes `stream` and waits for the taken byte. `completion` gets false
    /// if the other end closes without it or stops reading.
    private static func writeStream(_ connection: NWConnection, _ stream: Data,
                                    idle: TimeInterval, completion: @escaping (Bool) -> Void) {
        var offset = 0
        var finished = false
        var watchdog: Watchdog?

        func finish(_ taken: Bool) {
            guard !finished else { return }
            finished = true
            watchdog?.stop()
            connection.cancel()
            completion(taken)
        }

        watchdog = Watchdog(idle: idle) { finish(false) }

        func next() {
            watchdog?.arm()

            guard offset < stream.count else {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
                    data, _, _, error in
                    finish(error == nil && data?.first == ClipStream.taken)
                }
                return
            }

            let end = min(offset + writePiece, stream.count)
            let piece = stream.subdata(in: (stream.startIndex + offset)..<(stream.startIndex + end))
            connection.send(content: piece, completion: .contentProcessed { error in
                guard error == nil else {
                    finish(false)
                    return
                }
                offset = end
                next()
            })
        }
        next()
    }

    // MARK: - This computer's addresses

    /// False for loopback and link-local (useless without its interface).
    static func reachable(_ address: ClipAddress) -> Bool {
        let bytes = address.bytes
        if address.isIPv4 {
            return bytes[0] != 127 && !(bytes[0] == 169 && bytes[1] == 254)
        }
        let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
        return !loopback && !(bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
    }

    /// Addresses another computer on the network could reach: every interface
    /// that is up, minus loopback and link-local, IPv4 first.
    static func localAddresses() -> [ClipAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var v4: [ClipAddress] = []
        var v6: [ClipAddress] = []
        var cursor = head

        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let raw = entry.ifa_addr
            else { continue }

            switch Int32(raw.pointee.sa_family) {
            case AF_INET:
                let bytes = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                }
                if let address = ClipAddress(bytes), reachable(address) {
                    v4.append(address)
                }
            case AF_INET6:
                let bytes = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
                if let address = ClipAddress(bytes), reachable(address) {
                    v6.append(address)
                }
            default:
                break
            }
        }

        var seen: [ClipAddress] = []
        for address in v4 + v6 where !seen.contains(address) {
            seen.append(address)
        }
        return Array(seen.prefix(ClipMessage.maxAddresses))
    }
}
