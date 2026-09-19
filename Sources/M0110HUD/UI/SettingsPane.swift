import SwiftUI

/// HUD preferences, persisted under the same `UserDefaults` keys `Config` reads
/// at launch, so the CLI flags and this pane stay in sync.
struct SettingsPane: View {
    @AppStorage("scale") private var scale: Double = 1.0
    @AppStorage("insetX") private var insetX: Double = 110
    @AppStorage("insetY") private var insetY: Double = 6
    @AppStorage("hudDuration") private var duration: Double = 3.2
    @AppStorage("lowThreshold") private var lowThreshold: Int = 20
    @AppStorage("rearmThreshold") private var rearmThreshold: Int = 30
    @AppStorage("showDisconnect") private var showDisconnect: Bool = true
    @AppStorage("suppressInitial") private var suppressInitial: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("Popup") {
                slider("Scale", $scale, 0.5...2.5, 0.05, "%.2f×")
                slider("Inset from right edge", $insetX, 0...400, 2, "%.0f pt")
                slider("Gap below menu bar", $insetY, 0...40, 1, "%.0f pt")
                slider("Visible for", $duration, 1...12, 0.2, "%.1f s")
            }

            group("Battery") {
                stepper("Low battery at", $lowThreshold, 5...60)
                stepper("Re-arm alert at", $rearmThreshold, 10...90)
                if rearmThreshold <= lowThreshold {
                    Label("Re-arm must exceed the low threshold, or the alert latches off. "
                          + "It is clamped to low + 10 at launch.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.small)
                        .foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            group("Events") {
                toggle("Show a popup on disconnect", $showDisconnect)
                toggle("Stay quiet if already connected at launch", $suppressInitial)
                Text("These are read when the app starts, so changes take effect next launch. "
                     + "Command-line flags override them for a single run.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
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

    private func slider(_ label: String, _ value: Binding<Double>,
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

    private func stepper(_ label: String, _ value: Binding<Int>,
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

    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(Theme.body).foregroundStyle(Theme.textDim)
            Spacer()
            ThemeSwitch(isOn: isOn)
        }
    }
}
