import Foundation

/// %LOCALAPPDATA%\M0110HUD, which holds what the Mac keeps in UserDefaults.
enum AppFiles {
    static var directory: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("M0110HUD", isDirectory: true)
    }

    static var state: URL { directory.appendingPathComponent("state.json") }
    static var settings: URL { directory.appendingPathComponent("settings.json") }
}

/// Announcer state in a JSON file, rewritten on every change (a few times a day).
final class FileMemory: AnnouncerMemory {
    private struct State: Codable {
        var lowAlertArmed = true
        var lastMilestone: Int?
        var lastConnectAt: Date?
        var lastDisconnectAt: Date?
        var lastBattery: Int?
        var diedAnnounced = false
    }

    private let url: URL
    private var state: State {
        didSet { save() }
    }

    init(url: URL) {
        self.url = url
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    var lowAlertArmed: Bool {
        get { state.lowAlertArmed }
        set { state.lowAlertArmed = newValue }
    }
    var lastMilestone: Int? {
        get { state.lastMilestone }
        set { state.lastMilestone = newValue }
    }
    var lastConnectAt: Date? {
        get { state.lastConnectAt }
        set { state.lastConnectAt = newValue }
    }
    var lastDisconnectAt: Date? {
        get { state.lastDisconnectAt }
        set { state.lastDisconnectAt = newValue }
    }
    var lastBattery: Int? {
        get { state.lastBattery }
        set { state.lastBattery = newValue }
    }
    var diedAnnounced: Bool {
        get { state.diedAnnounced }
        set { state.diedAnnounced = newValue }
    }
}

/// settings.json. Every field is optional, so a partial hand-written file still loads.
///
///     { "profileNames": ["MacBook", "Windows PC"], "hudDuration": 5 }
struct WinSettings: Codable, Equatable {
    /// Local copy of the names stored on the keyboard (see ProfileNameStore).
    var profileNames: [String]?
    /// Renames not yet accepted by the keyboard, keyed by profile.
    var profileNamesPending: [String: String]?
    /// True once the local names have been offered to the keyboard.
    var profileNamesCarriedOver: Bool?
    var scale: Double?
    /// Measured from the right screen edge and up from the taskbar.
    var insetX: Double?
    var insetY: Double?
    var hudDuration: Double?
    var showDisconnect: Bool?
    var suppressInitial: Bool?
    var lowThreshold: Int?
    var rearmThreshold: Int?
    var clipboardSync: Bool?

    static let defaultInsetX = 12.0
    static let defaultInsetY = 12.0

    static func load() -> WinSettings {
        (try? JSONDecoder().decode(WinSettings.self, from: Data(contentsOf: AppFiles.settings))) ?? WinSettings()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: AppFiles.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: AppFiles.settings, options: .atomic)
    }

    /// For UserDefaults.register, so command-line flags still win.
    var defaults: [String: Any] {
        var d: [String: Any] = ["insetX": insetX ?? Self.defaultInsetX, "insetY": insetY ?? Self.defaultInsetY]
        if let scale { d["scale"] = scale }
        if let hudDuration { d["hudDuration"] = hudDuration }
        if let showDisconnect { d["showDisconnect"] = showDisconnect }
        if let suppressInitial { d["suppressInitial"] = suppressInitial }
        if let lowThreshold { d["lowThreshold"] = lowThreshold }
        if let rearmThreshold { d["rearmThreshold"] = rearmThreshold }
        return d
    }

    /// `index` is 0-based. Falls back to "Profile N".
    func profileName(_ index: Int) -> String {
        if let profileNames, index < profileNames.count {
            let name = profileNames[index].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return "Profile \(index + 1)"
    }
}
