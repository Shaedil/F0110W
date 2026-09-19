import SwiftUI

/// A feature this build has no hardware for. Shown honestly rather than as mock
/// controls that would imply the keyboard can do something it cannot.
struct FeatureGapPane: View {
    let title: String
    let summary: String
    let requiresHardware: [String]
    let firmwareNote: String
    let availableToday: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warn)
                        Text("No supporting hardware on this build")
                            .font(Theme.sectionTitle)
                            .foregroundStyle(Theme.text)
                    }
                    Text(summary)
                        .font(Theme.body)
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            section("Would require", items: requiresHardware)
            section("Firmware", items: [firmwareNote])
            if let availableToday {
                section("Available today", items: [availableToday], tint: Theme.good)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func section(_ heading: String, items: [String], tint: Color? = nil) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text(heading)
                    .font(Theme.sectionTitle)
                    .foregroundStyle(tint ?? Theme.text)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(Theme.textDim)
                            .frame(width: 3, height: 3)
                            .padding(.top, 6)
                        Text(item)
                            .font(Theme.body)
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension FeatureGapPane {
    static let gestures = FeatureGapPane(
        title: "Gestures",
        summary: "The M0110 is a 1984 matrix keyboard that talks to the converter over a "
            + "two-wire clock/data protocol. It reports key make and break codes and nothing "
            + "else. There is no touch surface, dial, or trackpad to read gestures from.",
        requiresHardware: [
            "A capacitive touch surface, encoder, or dial wired to spare nice!nano GPIO",
            "A ZMK input driver for that sensor (pointing or encoder subsystem)",
        ],
        firmwareNote: "The kscan driver in config/drivers/kscan/kscan_m0110.c decodes the "
            + "M0110 serial protocol only. Gesture input would be a separate device, not an "
            + "extension of it.",
        availableToday: "Per-key tap versus hold already works in firmware via ZMK hold-tap "
            + "behaviours, with no new hardware. That is a keymap feature rather than gesture "
            + "sensing, and could be surfaced in the Keys pane."
    )

    static let backlight = FeatureGapPane(
        title: "Backlight",
        summary: "The M0110 has no LEDs. Its keycaps are unlit and the matrix carries no "
            + "lighting rail, so there is nothing for a backlight control to drive.",
        requiresHardware: [
            "LEDs plus a driver on a PWM-capable nice!nano pin",
            "Or addressable RGB (WS2812) on a data pin, for underglow",
        ],
        firmwareNote: "ZMK does support this (CONFIG_ZMK_BACKLIGHT for PWM and "
            + "CONFIG_ZMK_RGB_UNDERGLOW for addressable strips), but neither is enabled in "
            + "config/m0110.conf, and the shield overlay declares no LED nodes.",
        availableToday: "The nice!nano has one onboard blue LED on P0.15, already declared in "
            + "the board devicetree. That is a status LED, not a backlight, but it could be "
            + "driven for connection or charge indication."
    )

    static let audio = FeatureGapPane(
        title: "Audio",
        summary: "There is no speaker, piezo, or buzzer anywhere in this build, on either "
            + "the M0110 or the nice!nano.",
        requiresHardware: [
            "A piezo buzzer or small speaker on a PWM-capable pin",
            "A series resistor or driver transistor depending on the element",
        ],
        firmwareNote: "ZMK mainline has no audio subsystem, so this would mean a custom "
            + "Zephyr PWM tone driver plus a ZMK behaviour to trigger it, rather than a "
            + "config flag.",
        availableToday: nil
    )

    static let haptics = FeatureGapPane(
        title: "Haptics",
        summary: "No haptic actuator is fitted. The converter drives the keyboard's original "
            + "mechanical switches, whose feel is fixed by the 1984 hardware.",
        requiresHardware: [
            "An LRA or ERM motor with a driver such as a DRV2605L",
            "I²C wiring to the nice!nano, plus current the 5V boost budget can spare",
        ],
        firmwareNote: "ZMK mainline has no haptics subsystem. Community modules exist, but "
            + "they would need porting into this config as an external module.",
        availableToday: nil
    )
}
