import Foundation

/// The app's own record of what it saw and decided, for working out after
/// the fact why a HUD did or did not show.
///
/// The last lines are kept in memory for the Logs tab in Settings, and every
/// line is appended to `~/Library/Logs/M0110HUD/M0110HUD.log`, so a copy
/// started at login, whose stdout goes nowhere, still leaves a trail. With
/// `--verbose` each line is printed as well.
///
/// Lines come from any thread: the Bluetooth monitor's arrive on the main
/// queue, the clipboard's and the Studio link's on their own.
final class DebugLog: ObservableObject {
    /// Writes to the file only once the app turns that on: snapshots and
    /// tests drive the same code with made-up state.
    static let shared = DebugLog(file: DebugLog.defaultFile, persists: false)

    static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/M0110HUD/M0110HUD.log")
    }

    /// Where a line came from, which the Logs tab filters on.
    enum Source: String, CaseIterable {
        /// The HUD's own decisions: what it showed, and why it showed nothing.
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

        /// One line as written to the file and copied out of the Logs tab.
        var line: String {
            "\(DebugLog.stamp.string(from: date)) [\(source.rawValue)] \(message)"
        }
    }

    /// The last `capacity` lines, oldest first, for the Logs tab. Updated on
    /// the main thread, a moment after the lines arrive.
    @Published private(set) var entries: [Entry] = []

    /// Print each line too, for `--verbose`.
    var echo = false
    /// Whether lines go to the file. Off for the debug panel and UI dev runs,
    /// whose events are made up and would read there as if the keyboard had
    /// done them.
    var persists: Bool

    let file: URL?
    let capacity: Int
    /// Past this the file is moved aside to `.1.log`, replacing the last one,
    /// so the two never take more than twice this.
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
        // The clipboard names itself in its own messages; the tag says it once.
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
        // One publish per burst, rather than one per line.
        if schedule { DispatchQueue.main.async { self.publish() } }
    }

    /// What is held now, without waiting for the main thread to catch up.
    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Forget the lines held in memory. The file keeps them.
    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        DispatchQueue.main.async { self.publish() }
    }

    /// Wait for the lines added so far to reach the file.
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
