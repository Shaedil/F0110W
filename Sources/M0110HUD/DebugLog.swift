import Foundation

/// The app's log, for finding out later why a HUD did or did not show.
/// Recent lines stay in memory for the Logs tab. Every line also goes to
/// `~/Library/Logs/M0110HUD/M0110HUD.log`, since a copy started at login has no stdout.
/// Lines can come from any thread.
final class DebugLog: ObservableObject {
    /// File writes stay off until the app turns them on, since snapshots and tests use made-up state.
    static let shared = DebugLog(file: DebugLog.defaultFile, persists: false)

    static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/M0110HUD/M0110HUD.log")
    }

    /// The Logs tab filters on this.
    enum Source: String, CaseIterable {
        /// What the HUD showed, or why it showed nothing.
        case app
        case bluetooth
        case clipboard
        case studio

        var label: String {
            switch self {
            case .app: return "App"
            case .bluetooth: return "Bluetooth"
            case .clipboard: return "Clipboard"
            case .studio: return "Studio"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let date: Date
        let source: Source
        let message: String

        /// Format used in the file and when copying from the Logs tab.
        var line: String {
            "\(DebugLog.stamp.string(from: date)) [\(source.rawValue)] \(message)"
        }
    }

    /// Last `capacity` lines, oldest first. Updated on the main thread shortly after lines arrive.
    @Published private(set) var entries: [Entry] = []

    var echo = false
    /// Off for the debug panel and UI dev runs, whose made-up events would look real in the file.
    var persists: Bool

    let file: URL?
    let capacity: Int
    /// Past this size the file is renamed to `.1.log`, replacing the old one, so the two files
    /// never take more than twice this.
    let maxFileBytes: Int

    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var nextID = 0
    private var publishPending = false
    private let io = DispatchQueue(label: "com.shaedil.m0110hud.log")
    private var handle: FileHandle?

    init(file: URL?, capacity: Int = 2000, maxFileBytes: Int = 2_000_000,
         persists: Bool = true) {
        self.file = file
        self.persists = persists
        self.capacity = capacity
        self.maxFileBytes = maxFileBytes
    }

    func add(_ source: Source, _ message: String, at date: Date = Date()) {
        // The clipboard puts its name in its messages. Drop it, since the tag already shows it.
        let prefix = "\(source.rawValue): "
        let text = message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message

        lock.lock()
        let entry = Entry(id: nextID, date: date, source: source, message: text)
        nextID += 1
        buffer.append(entry)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        let schedule = !publishPending
        publishPending = true
        lock.unlock()

        if echo { print("[\(Self.clock.string(from: date))] \(source.rawValue): \(text)") }
        if persists, file != nil { io.async { self.write(entry.line) } }
        // Publish once per burst instead of once per line.
        if schedule { DispatchQueue.main.async { self.publish() } }
    }

    /// Current lines, without waiting for the main thread.
    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Clears memory only. The file keeps the lines.
    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        DispatchQueue.main.async { self.publish() }
    }

    func flush() {
        io.sync {}
    }

    private func publish() {
        lock.lock()
        let current = buffer
        publishPending = false
        lock.unlock()
        if entries != current { entries = current }
    }

    /// Must run on `io`.
    private func write(_ line: String) {
        guard let file else { return }
        if handle == nil { handle = open(file) }
        if let size = try? handle?.offset(), size >= UInt64(maxFileBytes) {
            try? handle?.close()
            let old = Self.rotated(file)
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: file, to: old)
            handle = open(file)
        }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// `M0110HUD.log` becomes `M0110HUD.1.log`.
    static func rotated(_ file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("1.log")
    }

    private func open(_ file: URL) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
