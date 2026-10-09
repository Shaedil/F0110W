import SwiftUI

/// The Settings pane's sections, one at a time.
enum SettingsTab: String, CaseIterable {
    case popup = "Popup"
    case clipboard = "Clipboard"
    case logs = "Logs"
}

/// HUD preferences, persisted under the same `UserDefaults` keys `Config` reads
/// at launch, so the CLI flags and this pane stay in sync.
struct SettingsPane: View {
    @AppStorage("scale") private var scale: Double = 1.0
    @AppStorage("insetX") private var insetX: Double = 110
    @AppStorage("insetY") private var insetY: Double = 6
    @AppStorage("hudDuration") private var duration: Double = 3.2
    @AppStorage("showDisconnect") private var showDisconnect: Bool = true
    @AppStorage("suppressInitial") private var suppressInitial: Bool = false
    @AppStorage(ClipboardBridge.enabledKey) private var clipboardSync: Bool = true

    /// The tab showing, remembered across launches.
    @AppStorage("settingsTab") private var tab: SettingsTab = .popup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SegmentPills(options: SettingsTab.allCases.map { ($0, $0.rawValue) },
                         selection: $tab)

            switch tab {
            case .popup:
                popup
                events
            case .clipboard:
                clipboard
            case .logs:
                LogsTab()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var popup: some View {
        settingsGroup("Popup") {
            settingsSlider("Scale", $scale, 0.5...2.5, 0.05, "%.2f×")
            settingsSlider("Inset from right edge", $insetX, 0...400, 2, "%.0f pt")
            settingsSlider("Gap below menu bar", $insetY, 0...40, 1, "%.0f pt")
            settingsSlider("Visible for", $duration, 1...12, 0.2, "%.1f s")
        }
    }

    private var events: some View {
        settingsGroup("Events") {
            settingsToggle("Show a popup on disconnect", $showDisconnect)
            settingsToggle("Stay quiet if already connected at launch", $suppressInitial)
            Text("These are read when the app starts, so changes take effect next launch. "
                 + "Command-line flags override them for a single run.")
                .font(Theme.small)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var clipboard: some View {
        settingsGroup("Clipboard") {
            settingsToggle("Carry copied text to the keyboard's other computers", $clipboardSync)
            // The last words are held together so no width can strand one.
            Text("Text copied here goes with the keyboard when it switches computers: "
                 + "onto that computer's clipboard if this app runs there, typed out if "
                 + "not. Concealed passwords are never\u{00A0}sent.")
                .font(Theme.small)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Low-battery alert thresholds, on their own sidebar pane.
struct BatteryPane: View {
    @AppStorage("lowThreshold") private var lowThreshold: Int = 20
    @AppStorage("rearmThreshold") private var rearmThreshold: Int = 30

    var body: some View {
        settingsGroup("Low battery alert") {
            settingsStepper("Low battery at", $lowThreshold, 5...60)
            settingsStepper("Re-arm alert at", $rearmThreshold, 10...90)
            if rearmThreshold <= lowThreshold {
                Label("Re-arm must exceed the low threshold, or the alert latches off. "
                      + "It is clamped to low + 10 at launch.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.small)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The keyboard's Bluetooth profiles, on their own sidebar pane.
struct BluetoothPane: View {
    var body: some View {
        settingsGroup("Profiles") {
            ForEach(0..<ProfileNames.count, id: \.self) { index in
                profileField(index)
            }
            // Short enough for one line, so there is no last line to orphan.
            Text("Shown when the keyboard switches away, as in \"Moved to Work\u{00A0}Laptop\".")
                .font(Theme.small)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Rows shared by the settings panes

func settingsGroup<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
    let body = content()
    return Panel {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.sectionTitle)
                .foregroundStyle(Theme.text)
            body
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func settingsSlider(_ label: String, _ value: Binding<Double>,
                    _ range: ClosedRange<Double>, _ step: Double,
                    _ format: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        HStack {
            Text(label).font(Theme.body).foregroundStyle(Theme.textDim)
            Spacer()
            Text(String(format: format, value.wrappedValue))
                .font(Theme.small.monospacedDigit())
                .foregroundStyle(Theme.text)
        }
        ThemeSlider(value: value, range: range, step: step)
    }
}

func settingsStepper(_ label: String, _ value: Binding<Int>,
                     _ range: ClosedRange<Int>) -> some View {
    HStack {
        Text(label).font(Theme.body).foregroundStyle(Theme.textDim)
        Spacer()
        Text("\(value.wrappedValue)%")
            .font(Theme.small.monospacedDigit())
            .foregroundStyle(Theme.text)
        ThemeStepper(value: value, range: range)
    }
}

/// One profile's name, written straight to the key ProfileNames reads, so
/// a rename shows on the very next HUD.
func profileField(_ index: Int) -> some View {
    let name = Binding<String>(
        get: { UserDefaults.standard.string(forKey: ProfileNames.key(index)) ?? "" },
        set: { UserDefaults.standard.set($0, forKey: ProfileNames.key(index)) })
    return HStack {
        Text("Profile \(index + 1)").font(Theme.body).foregroundStyle(Theme.textDim)
        Spacer()
        TextField("", text: name, prompt: Text("Profile \(index + 1)"))
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
    }
}

func settingsToggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
    HStack {
        Text(label).font(Theme.body).foregroundStyle(Theme.textDim)
        Spacer()
        ThemeSwitch(isOn: isOn)
    }
}
