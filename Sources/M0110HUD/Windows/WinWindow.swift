import CM0110Web
import CM0110Win
import Foundation

/// The M0110 window, the WindowsUI page in WebView2. The page sends small JSON
/// messages with a "type", and the app answers with whole states to draw.
final class WinWindow {
    /// For the C callbacks, which carry no context.
    private static var current: WinWindow?

    var onMessage: ((_ type: String, _ body: [String: Any]) -> Void)?
    var onClosed: (() -> Void)?

    private let verbose: Bool
    /// Set when the page says it is listening, cleared on close. Earlier posts would be lost.
    private(set) var isReady = false

    /// The whole window at 96 DPI, including the page's own 32 px title bar. The page
    /// resizes it later.
    static let size = (width: Int32(1340), height: Int32(585 + 32))

    init(verbose: Bool) {
        self.verbose = verbose
    }

    var isOpen: Bool { m0110_web_is_open() != 0 }

    func open() {
        Self.current = self
        var callbacks = m0110_web_callbacks(
            message: { json in
                guard let json else { return }
                WinWindow.current?.received(String(decodingCString: json, as: UTF16.self))
            },
            closed: { WinWindow.current?.closed() },
            failed: { WinWindow.current?.failed($0) })
        let data = AppFiles.directory.appendingPathComponent("WebView2", isDirectory: true)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let status = m0110_web_open("M0110".wide, Self.pageFolder.wide, data.path.wide, Self.size.width,
                                    Self.size.height, &callbacks)
        if status != 0 { log("window: could not open (\(hex(status)))", verbose: true) }
    }

    func close() { m0110_web_close() }

    /// Client size at 96 DPI.
    func resize(width: Int, height: Int) {
        m0110_web_resize(Int32(clamping: width), Int32(clamping: height))
    }

    func post<Message: Encodable>(_ message: Message) {
        guard isReady else { return }
        do {
            let data = try Self.encoder.encode(message)
            m0110_web_post(String(decoding: data, as: UTF8.self).wide)
        } catch {
            log("window: could not encode \(Message.self): \(error)", verbose: true)
        }
    }

    // MARK: From the page

    private func received(_ json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            log("window: unreadable message \(json.prefix(200))", verbose: verbose)
            return
        }
        if type == "ready" { isReady = true }
        log("window: \(type)", verbose: verbose)
        // The page's title bar buttons.
        switch type {
        case "window.minimize": m0110_web_minimize()
        case "window.close": m0110_web_request_close()
        case "window.drag": m0110_web_begin_drag()
        default: onMessage?(type, object)
        }
    }

    private func closed() {
        isReady = false
        log("window: closed", verbose: verbose)
        onClosed?()
    }

    private func failed(_ result: Int32) {
        log("window: WebView2 failed (\(hex(result)))", verbose: true)
        // HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) means the runtime is missing.
        let text = result == Int32(bitPattern: 0x8007_0002)
            ? "The M0110 window needs the Microsoft Edge WebView2 Runtime, which this PC does not have."
            : "The M0110 window could not start WebView2 (\(hex(result)))."
        m0110_message_box("M0110".wide, text.wide)
        close()
    }

    // MARK: Files

    /// The `ui` folder next to the exe (from build.ps1), unless M0110_UI_DIR overrides it.
    static var pageFolder: String {
        if let override = ProcessInfo.processInfo.environment["M0110_UI_DIR"], !override.isEmpty {
            return override
        }
        var path = [UInt16](repeating: 0, count: 4096)
        let length = Int(m0110_module_path(&path, UInt32(path.count)))
        let executable = URL(fileURLWithPath: String(decoding: path.prefix(length), as: UTF16.self))
        return executable.deletingLastPathComponent().appendingPathComponent("ui", isDirectory: true).path
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
