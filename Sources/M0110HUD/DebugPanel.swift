import AppKit
import SwiftUI

/// Drives the HUD by hand, for working on its look without the keyboard. Events go through
/// the same `AppDelegate` handlers `BluetoothMonitor` calls, so they behave as they do for real.
/// State is saved and the last HUD is shown again at launch, so a rebuild from
/// tools/hud-dev.sh shows the change right away.
@MainActor
final class DebugModel: ObservableObject {
    enum Link: String { case down, up }

    private unowned let app: AppDelegate
    private let store = UserDefaults(suiteName: "com.shaedil.m0110hud.debug") ?? .standard

    // MARK: State machine

    @Published private(set) var link: Link
    @Published var battery: Double { didSet { save("battery", battery) } }
    @Published private(set) var log: [String] = []
    /// Copies of the app's saved alert state, refreshed after every event.
    @Published private(set) var alertArmed = true
    @Published private(set) var milestone: Int?
    @Published private(set) var tourStep: Int

    // MARK: Look

    @Published var pinned: Bool {
        didSet { app.hud.pinned = pinned; save("pinned", pinned) }
    }
    @Published var appearance: String {
        didSet { applyAppearance(); save("appearance", appearance) }
    }
    @Published var followSystemTransparency: Bool {
        didSet { applyTransparency(); save("followSystemTransparency", followSystemTransparency) }
    }
    @Published var transparency: Double {
        didSet { applyTransparency(); save("transparency", transparency) }
    }
    /// "system", "on" or "off": the Reduce Motion variant to show.
    @Published var reduceMotion: String {
        didSet { applyReduceMotion(); save("reduceMotion", reduceMotion) }
    }
    @Published var material: String {
        didSet { app.config.material = material; rebuild(); save("material", material) }
    }
    @Published var scale: Double {
        didSet { app.config.scale = scale; rebuild(); save("scale", scale) }
    }
    @Published var name: String {
        didSet { app.config.deviceName = name; save("name", name) }
    }

    // MARK: Animation

    @Published var editingKind: HUDKind = .disconnected
    @Published private(set) var styles: [HUDKind: HUDStyle]

    /// Each change goes to the HUD and shows right away, so options are quick to compare.
    func style<T>(_ field: WritableKeyPath<HUDStyle, T>) -> Binding<T> {
        Binding(
            get: { [self] in styles[editingKind]![keyPath: field] },
            set: { [self] value in
                styles[editingKind]![keyPath: field] = value
                app.hud.styles = styles
                saveStyle(editingKind)
                preview(editingKind)
            })
    }

    func resetStyles() {
        styles = HUDStyle.defaults
        app.hud.styles = styles
        HUDKind.allCases.forEach(saveStyle)
        preview(editingKind)
    }

    /// Shows the state from off screen so the entrance animation plays too.
    func preview(_ kind: HUDKind) {
        app.hud.tearDown()
        show(kind, withBattery: kind != .disconnected)
    }

    private func saveStyle(_ kind: HUDKind) {
        guard let style = styles[kind] else { return }
        save("style.\(kind.rawValue)",
             [style.entrance.rawValue, style.motion.rawValue, style.treatment.rawValue])
    }

    private static func loadStyles(_ store: UserDefaults) -> [HUDKind: HUDStyle] {
        var styles = HUDStyle.defaults
        for kind in HUDKind.allCases {
            guard let parts = store.stringArray(forKey: "debug.style.\(kind.rawValue)"), parts.count == 3,
                  let entrance = HUDEntrance(rawValue: parts[0]),
                  let motion = BoardMotion(rawValue: parts[1]),
                  let treatment = BoardTreatment(rawValue: parts[2]) else { continue }
            styles[kind] = HUDStyle(entrance: entrance, motion: motion, treatment: treatment)
        }
        return styles
    }

    // MARK: Config

    @Published var duration: Double {
        didSet { app.config.hudDuration = duration; rebuild(); save("duration", duration) }
    }
    @Published var lowThreshold: Int {
        didSet {
            app.config.lowThreshold = lowThreshold
            // As in Config.resolve: a re-arm at or below the trigger latches forever.
            if rearmThreshold <= lowThreshold { rearmThreshold = min(lowThreshold + 10, 100) }
            rebuild()
            save("lowThreshold", lowThreshold)
        }
    }
    @Published var rearmThreshold: Int {
        didSet { app.config.rearmThreshold = rearmThreshold; save("rearmThreshold", rearmThreshold) }
    }
    @Published var milestoneStep: Int {
        didSet { app.config.batteryMilestone = milestoneStep; save("milestoneStep", milestoneStep) }
    }
    @Published var showDisconnect: Bool {
        didSet { app.config.showDisconnect = showDisconnect; save("showDisconnect", showDisconnect) }
    }
    @Published var suppressInitial: Bool {
        didSet { app.config.suppressInitial = suppressInitial; save("suppressInitial", suppressInitial) }
    }

    static let materials = ["toolTip", "hudWindow", "popover", "menu", "sidebar",
                            "headerView", "windowBackground", "contentBackground",
                            "underWindowBackground", "fullScreenUI", "titlebar",
                            "selection", "sheet"]

    /// Counts HUDs shown, so an event that produced none can say so.
    private var shows = 0

    init(app: AppDelegate) {
        self.app = app
        let s = store
        let c = app.config
        func value<T>(_ key: String, _ fallback: T) -> T { s.object(forKey: "debug.\(key)") as? T ?? fallback }

        link = Link(rawValue: value("link", "down")) ?? .down
        battery = value("battery", 76.0)
        tourStep = value("tourStep", 0)
        pinned = value("pinned", true)
        appearance = value("appearance", "system")
        followSystemTransparency = value("followSystemTransparency", true)
        transparency = value("transparency", 1.0)
        reduceMotion = value("reduceMotion", "system")
        material = value("material", c.material)
        scale = value("scale", c.scale)
        name = value("name", c.deviceName)
        duration = value("duration", c.hudDuration)
        lowThreshold = value("lowThreshold", c.lowThreshold)
        rearmThreshold = value("rearmThreshold", c.rearmThreshold)
        milestoneStep = value("milestoneStep", c.batteryMilestone)
        showDisconnect = value("showDisconnect", c.showDisconnect)
        suppressInitial = value("suppressInitial", c.suppressInitial)
        styles = Self.loadStyles(s)
        clockOffset = value("clockOffset", 0.0)
        ownProfile = value("ownProfile", 0)

        // didSet does not run during init, so push everything across once.
        app.config.material = material
        app.config.scale = scale
        app.config.deviceName = name
        app.config.hudDuration = duration
        app.config.lowThreshold = lowThreshold
        app.config.rearmThreshold = rearmThreshold
        app.config.batteryMilestone = milestoneStep
        app.config.showDisconnect = showDisconnect
        app.config.suppressInitial = suppressInitial
        app.rebuildHUD()
        app.hud.pinned = pinned
        app.hud.styles = styles
        app.hud.onShow = { [weak self] kind, name, battery in self?.didShow(kind, name, battery) }
        // Stands in for the firmware command and reports the switch like the keyboard would.
        app.hud.onMoveBack = { [weak self] in
            guard let self else { return }
            append("· Move back clicked")
            switchProfile(to: ownProfile)
        }
        applyAppearance()
        applyTransparency()
        applyReduceMotion()
        syncLatch()
    }

    func replay() {
        guard let kind = store.string(forKey: "debug.lastKind").flatMap(HUDKind.init(rawValue:)) else { return }
        let level = store.object(forKey: "debug.lastBattery") as? Int
        app.hud.show(kind: kind, name: name, battery: level)
    }

    private var level: Int { Int(battery.rounded()) }

    // MARK: Clock and profiles

    /// Added to the real clock, to test the day's first connect without waiting a day.
    @Published private(set) var clockOffset: TimeInterval
    var now: Date { Date().addingTimeInterval(clockOffset) }

    @Published var ownProfile: Int { didSet { save("ownProfile", ownProfile) } }
    @Published private(set) var keyboardProfile: Int?

    var nextConnectIsArrival: Bool { app.isArrival(at: now) }
    var lastBatteryText: String { app.lastBattery.map { "\($0)%" } ?? "unknown" }

    func advanceClock(hours: Double) {
        clockOffset += hours * 3600
        save("clockOffset", clockOffset)
        append("· clock +\(Int(hours))h")
        objectWillChange.send()
    }

    func resetHistory() {
        app.resetHistory()
        clockOffset = 0
        save("clockOffset", clockOffset)
        keyboardProfile = nil
        resetLatch()
        append("· history reset: no connects, battery unknown, clock real")
    }

    func profileName(_ index: Int) -> Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: ProfileNames.key(index)) ?? "" },
            set: { [self] in
                UserDefaults.standard.set($0, forKey: ProfileNames.key(index))
                objectWillChange.send()
            })
    }

    func switchProfile(to index: Int) {
        event("keyboard switches to \(ProfileNames.name(for: index))") {
            keyboardProfile = index
            app.handleProfileSwitch(name: name, active: index, own: ownProfile)
        }
    }

    // MARK: Events

    func connect(withBattery: Bool, atLaunch: Bool = false) {
        event(atLaunch ? "connect (already up at launch)" : "connect\(withBattery ? " @ \(level)%" : ", battery pending")") {
            setLink(.up)
            app.handleConnect(name: name, battery: withBattery ? level : nil, isInitial: atLaunch, now: now)
            // On connect the keyboard is typing here, so this computer's profile is active.
            keyboardProfile = ownProfile
            app.handleProfileSwitch(name: name, active: ownProfile, own: ownProfile)
        }
    }

    func disconnect() {
        event("disconnect") {
            setLink(.down)
            keyboardProfile = nil
            app.handleDisconnect(name: name, now: now)
        }
    }

    func report(_ delta: Int = 0) {
        battery = Double(min(max(level + delta, 0), 100))
        event("battery report \(level)%") {
            app.handleBattery(name: name, level: level)
        }
    }

    func resetLatch() {
        app.lowAlertArmed = true
        app.lastMilestone = nil
        syncLatch()
        append("· latch reset: alert armed, no milestone")
    }

    // MARK: Direct

    func show(_ kind: HUDKind, withBattery: Bool) {
        let other = (ownProfile + 1) % ProfileNames.count
        app.hud.show(kind: kind, name: name, battery: withBattery ? level : nil,
                     detail: kind == .movedAway ? ProfileNames.name(for: other) : nil)
    }

    func dismiss() { app.hud.dismissNow() }

    // MARK: Tour

    /// A simulated day, one step per click, covering each change in what the HUD says.
    var tour: [(String, () -> Void)] {
        let other = (ownProfile + 1) % ProfileNames.count
        return [
            ("Reset: no history, link down", { [self] in
                resetHistory(); setLink(.down); app.hud.dismissNow() }),
            ("Arrive at work: first connect of the day", { [self] in
                battery = 76; connect(withBattery: false) }),
            ("Battery read lands at 76%", { [self] in battery = 76; report() }),
            ("Switch to \(ProfileNames.name(for: other))", { [self] in switchProfile(to: other) }),
            ("Switch back to this computer", { [self] in switchProfile(to: ownProfile) }),
            ("Drains to 45%: board starts to fade", { [self] in battery = 45; report() }),
            ("Drains to \(lowThreshold - 1)%: low battery, fainter", { [self] in
                battery = Double(lowThreshold - 1); report() }),
            ("Leave for lunch: disconnect", { [self] in disconnect() }),
            ("Back an hour later: ordinary connect", { [self] in
                advanceClock(hours: 1); connect(withBattery: true) }),
            ("Runs flat: 0%", { [self] in battery = 0; report() }),
            ("Dies: disconnect (already announced)", { [self] in disconnect() }),
            ("Next morning, charged: arrive", { [self] in
                advanceClock(hours: 14); battery = 100; connect(withBattery: true) }),
        ]
    }

    func nextStep() {
        let steps = tour
        let step = steps[tourStep % steps.count]
        append("▶ \(tourStep % steps.count + 1)/\(steps.count) \(step.0)")
        step.1()
        tourStep = (tourStep + 1) % steps.count
        save("tourStep", tourStep)
    }

    func restartTour() {
        tourStep = 0
        save("tourStep", tourStep)
    }

    var nextStepTitle: String { tour[tourStep % tour.count].0 }

    // MARK: Plumbing

    private func event(_ label: String, _ body: () -> Void) {
        append("→ \(label)")
        let before = shows
        body()
        if shows == before { append("    no HUD") }
        syncLatch()
    }

    private func didShow(_ kind: HUDKind, _ name: String, _ battery: Int?) {
        shows += 1
        append("    HUD \(kind.rawValue)\(battery.map { " \($0)%" } ?? "")")
        store.set(kind.rawValue, forKey: "debug.lastKind")
        if let battery {
            store.set(battery, forKey: "debug.lastBattery")
        } else {
            store.removeObject(forKey: "debug.lastBattery")
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func setLink(_ next: Link) {
        link = next
        save("link", next.rawValue)
    }

    private func syncLatch() {
        alertArmed = app.lowAlertArmed
        milestone = app.lastMilestone
    }

    private func rebuild() {
        app.rebuildHUD()
        replay()
    }

    private func applyAppearance() {
        // Nil follows the system, which uses the same live path as a system theme change.
        NSApp.appearance = switch appearance {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    private func applyReduceMotion() {
        app.hud.forceReduceMotion = switch reduceMotion {
        case "on": true
        case "off": false
        default: nil
        }
    }

    private func applyTransparency() {
        app.transparency.override = followSystemTransparency ? nil : transparency
    }

    private func save(_ key: String, _ value: Any) {
        store.set(value, forKey: "debug.\(key)")
    }

}

struct DebugPanelView: View {
    @ObservedObject var model: DebugModel
    @State private var directBattery = true

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                stateSection
                eventsSection
                profilesSection
                tourSection
                directSection
                animationSection
                lookSection
                configSection
            }
            .formStyle(.grouped)
            .frame(width: 400)

            Divider()
            logView
        }
        .frame(minHeight: 640)
    }

    private var stateSection: some View {
        Section("State") {
            LabeledContent("Link") {
                Text(model.link == .up ? "Connected" : "Disconnected")
                    .foregroundStyle(model.link == .up ? .green : .secondary)
            }
            LabeledContent("Low alert") {
                Text(model.alertArmed ? "Armed" : "Latched (re-arms at \(model.rearmThreshold)%)")
            }
            LabeledContent("Last milestone") {
                Text(model.milestone.map { "\($0)%" } ?? "none")
            }
            LabeledContent("Next connect") {
                Text(model.nextConnectIsArrival ? "First of the day" : "Ordinary")
            }
            LabeledContent("Last battery") { Text(model.lastBatteryText) }
            LabeledContent("Keyboard on") {
                Text(model.keyboardProfile.map { ProfileNames.name(for: $0) } ?? "unknown")
            }
            HStack {
                Text("Battery")
                Slider(value: $model.battery, in: 0...100, step: 1)
                Text("\(Int(model.battery))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var eventsSection: some View {
        Section("Events (real handlers)") {
            if model.link == .down {
                HStack {
                    Button("Connect") { model.connect(withBattery: true) }
                    Button("Connect, no battery yet") { model.connect(withBattery: false) }
                    Button("At launch") { model.connect(withBattery: true, atLaunch: true) }
                }
            } else {
                HStack {
                    Button("Report \(Int(model.battery))%") { model.report() }
                    Button("−1") { model.report(-1) }
                    Button("−5") { model.report(-5) }
                    Button("−10") { model.report(-10) }
                    Button("+5") { model.report(5) }
                    Button("+10") { model.report(10) }
                }
                Button("Disconnect") { model.disconnect() }
            }
            HStack {
                Button("Clock +1h") { model.advanceClock(hours: 1) }
                Button("+5h") { model.advanceClock(hours: 5) }
                Button("+14h") { model.advanceClock(hours: 14) }
                Spacer()
                Button("Reset history") { model.resetHistory() }
            }
            Button("Reset alert latch and milestone") { model.resetLatch() }
        }
    }

    private var profilesSection: some View {
        Section("Profiles") {
            Picker("This computer is", selection: $model.ownProfile) {
                ForEach(0..<ProfileNames.count, id: \.self) { Text("\($0 + 1)").tag($0) }
            }
            .pickerStyle(.segmented)
            if model.link == .up {
                HStack {
                    Text("Switch keyboard to")
                    ForEach(0..<ProfileNames.count, id: \.self) { i in
                        Button("\(i + 1)") { model.switchProfile(to: i) }
                            .disabled(model.keyboardProfile == i)
                    }
                }
            } else {
                Text("Connect first to switch profiles.").foregroundStyle(.secondary)
            }
            ForEach(0..<ProfileNames.count, id: \.self) { i in
                TextField("Profile \(i + 1) name", text: model.profileName(i),
                          prompt: Text("Profile \(i + 1)"))
            }
        }
    }

    private var tourSection: some View {
        Section("Walk the graph") {
            HStack {
                Button("Next ▶") { model.nextStep() }
                    .keyboardShortcut(.return, modifiers: [])
                Text(model.nextStepTitle).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Restart") { model.restartTour() }
            }
        }
    }

    private var directSection: some View {
        Section("Show directly") {
            HStack {
                Button("Arrived") { model.show(.arrived, withBattery: directBattery) }
                Button("Connected") { model.show(.connected, withBattery: directBattery) }
                Button("Low Battery") { model.show(.lowBattery, withBattery: true) }
                Button("Disconnected") { model.show(.disconnected, withBattery: false) }
            }
            HStack {
                Button("Died") { model.show(.died, withBattery: true) }
                Button("Moved to") { model.show(.movedAway, withBattery: true) }
                Button("Moved back") { model.show(.movedBack, withBattery: true) }
                Spacer()
                Button("Dismiss") { model.dismiss() }
            }
            Toggle("Use the battery slider (ring and board fade)", isOn: $directBattery)
        }
    }

    private var animationSection: some View {
        Section("Animation per state") {
            Picker("State", selection: $model.editingKind) {
                Text("Arrived (first of day)").tag(HUDKind.arrived)
                Text("Connected").tag(HUDKind.connected)
                Text("Low Battery").tag(HUDKind.lowBattery)
                Text("Disconnected").tag(HUDKind.disconnected)
                Text("Died").tag(HUDKind.died)
                Text("Moved to").tag(HUDKind.movedAway)
                Text("Moved back").tag(HUDKind.movedBack)
            }
            Picker("Entrance", selection: model.style(\.entrance)) {
                ForEach(HUDEntrance.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Board", selection: model.style(\.motion)) {
                ForEach(BoardMotion.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Tint", selection: model.style(\.treatment)) {
                ForEach(BoardTreatment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Reduce Motion", selection: $model.reduceMotion) {
                Text("System").tag("system")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Replay") { model.preview(model.editingKind) }
                Spacer()
                Button("Reset all to defaults") { model.resetStyles() }
            }
        }
    }

    private var lookSection: some View {
        Section("Look") {
            Toggle("Pin HUD on screen", isOn: $model.pinned)
            Picker("Appearance", selection: $model.appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Toggle("Transparency follows system", isOn: $model.followSystemTransparency)
            if !model.followSystemTransparency {
                HStack {
                    Slider(value: $model.transparency, in: 0...1)
                    Text(String(format: "%.2f", model.transparency)).monospacedDigit()
                }
            }
            Picker("Material", selection: $model.material) {
                ForEach(DebugModel.materials, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Text("Scale")
                Slider(value: $model.scale, in: 0.5...2.5, step: 0.05)
                Text(String(format: "%.2f", model.scale)).monospacedDigit()
            }
            TextField("Name", text: $model.name)
        }
    }

    private var configSection: some View {
        Section("Config") {
            Stepper("Hold \(Int(model.duration))s", value: $model.duration, in: 1...30)
            Stepper("Low at \(model.lowThreshold)%", value: $model.lowThreshold, in: 1...90)
            Stepper("Re-arm at \(model.rearmThreshold)%", value: $model.rearmThreshold,
                    in: (model.lowThreshold + 1)...100)
            Stepper("Milestone every \(model.milestoneStep)%", value: $model.milestoneStep, in: 0...50, step: 5)
            Toggle("HUD on disconnect", isOn: $model.showDisconnect)
            Toggle("Quiet when connected at launch", isOn: $model.suppressInitial)
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption, design: .monospaced)).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .onReceive(model.$log) { log in
                if !log.isEmpty { proxy.scrollTo(log.count - 1, anchor: .bottom) }
            }
        }
        .frame(minWidth: 260)
    }
}

/// Its frame is autosaved, so it reopens in the same place across rebuilds.
@MainActor
final class DebugPanelController {
    private let window: NSWindow
    private let model: DebugModel

    init(app: AppDelegate) {
        model = DebugModel(app: app)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "M0110 HUD Debug"
        window.contentView = NSHostingView(rootView: DebugPanelView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("M0110HUDDebug")
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        model.replay()
    }
}
