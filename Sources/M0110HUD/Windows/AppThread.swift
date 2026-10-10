import CM0110Win
import Foundation

/// The app thread's work queue and timers, run by the Win32 message loop in
/// CM0110Win. Stands in for the main dispatch queue, which nothing drains on
/// Windows while a Win32 loop owns the thread.
enum Main {
    private static let lock = NSLock()
    private static var queued: [() -> Void] = []
    private static var timers: [UInt32: () -> Void] = [:]
    private static var nextTimer: UInt32 = 1

    /// Runs `work` on the app thread soon. Safe from any thread.
    static func async(_ work: @escaping () -> Void) {
        lock.lock()
        queued.append(work)
        lock.unlock()
        m0110_app_wake()
    }

    /// Runs `work` once, `seconds` from now. App thread only.
    @discardableResult
    static func after(_ seconds: Double, _ work: @escaping () -> Void) -> UInt32 {
        let id = nextTimer
        nextTimer = nextTimer == .max ? 1 : nextTimer + 1
        timers[id] = work
        m0110_timer_start(id, UInt32(max(0, seconds * 1000).rounded()))
        return id
    }

    static func cancel(_ id: UInt32?) {
        guard let id else { return }
        timers[id] = nil
        m0110_timer_stop(id)
    }

    /// Wired to CM0110Win's callbacks.
    static func drain() {
        lock.lock()
        let work = queued
        queued.removeAll()
        lock.unlock()
        for item in work { item() }
    }

    static func fire(_ id: UInt32) {
        timers.removeValue(forKey: id)?()
    }

    /// Seconds on a clock that only goes forward.
    static var now: Double { ProcessInfo.processInfo.systemUptime }
}

extension String {
    /// NUL-terminated UTF-16, as the C layer takes strings.
    var wide: [UInt16] { Array(utf16) + [0] }

    /// A NUL-terminated UTF-16 buffer the C layer filled in.
    init(wide buffer: [UInt16]) {
        self.init(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }
}

/// Timestamped lines for --verbose, as the Mac app prints them. Every line
/// is also kept among the last few, which hang.log shows when the app stops
/// answering.
func log(_ message: String, verbose: Bool) {
    m0110_trace(message)
    guard verbose else { return }
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(message)")
}

/// A Win32 or HRESULT code as Windows prints it.
func hex(_ code: Int32) -> String {
    String(format: "0x%08X", UInt32(bitPattern: code))
}
