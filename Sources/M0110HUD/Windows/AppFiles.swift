import Foundation

/// Where the Windows app keeps what the Mac keeps in UserDefaults:
/// %LOCALAPPDATA%\M0110HUD.
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

/// The announcer's memory, in a JSON file rewritten on every change. Changes
/// are rare: a few a day.
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

/// settings.json: what the window's Bluetooth, Battery and Settings panes
/// set, which the Mac keeps in UserDefaults. Every field is optional, so a
/// hand-written file with only some of them still loads.
///
///     { "profileNames": ["MacBook", "Windows PC"], "hudDuration": 5 }
struct WinSettings: Codable, Equatable {
    /// This PC's copy of the names the keyboard keeps; see ProfileNameStore.
    var profileNames: [String]?
    /// Renames made here the keyboard has not taken yet, by profile.
    var profileNamesPending: [String: String]?
    /// Whether the names here have been offered to the keyboard once.
    var profileNamesCarriedOver: Bool?
    var scale: Double?
    /// From the right edge of the screen, and up from the taskbar: where the
    /// Mac measures from the menu bar, Windows measures from the tray.
    var insetX: Double?
    var insetY: Double?
    var hudDuration: Double?
    var showDisconnect: Bool?
    var suppressInitial: Bool?
    var lowThreshold: Int?
    var rearmThreshold: Int?
    /// Whether the clipboard is carried to and from the keyboard.
    var clipboardSync: Bool?

    /// The Windows HUD's own resting place, a tray-corner margin, where the
    /// Mac's defaults clear its menu bar icons.
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

    /// For UserDefaults.register, under Config's command-line flags.
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

    /// The name for a 0-based profile, or "Profile N" as on the Mac.
    func profileName(_ index: Int) -> String {
        if let profileNames, index < profileNames.count {
            let name = profileNames[index].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return "Profile \(index + 1)"
    }
}
