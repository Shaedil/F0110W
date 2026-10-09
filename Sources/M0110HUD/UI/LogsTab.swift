import AppKit
import SwiftUI

/// Which lines the Logs tab shows.
enum LogFilter: String, CaseIterable {
    case all
    case app
    case bluetooth
    case clipboard
    case studio

    var label: String {
        switch self {
        case .all: return "All"
        case .app: return DebugLog.Source.app.label
        case .bluetooth: return DebugLog.Source.bluetooth.label
        case .clipboard: return DebugLog.Source.clipboard.label
        case .studio: return DebugLog.Source.studio.label
        }
    }

    func admits(_ entry: DebugLog.Entry) -> Bool {
        self == .all || entry.source.rawValue == rawValue
    }
}

/// Settings' Logs tab: what the app saw from the keyboard and what it did
/// about it, newest at the bottom. Made for the question "why did that popup
/// not show", whose answer is usually in the Bluetooth and App lines.
struct LogsTab: View {
    @ObservedObject private var log = DebugLog.shared
    /// Remembered, since a run of debugging tends to look at one source.
    @AppStorage("logsFilter") private var filter: LogFilter = .all
    @Environment(\.classicSnapshot) private var snapshot

    private var shown: [DebugLog.Entry] { log.entries.filter(filter.admits) }

    var body: some View {
        settingsGroup("Logs") {
            SegmentPills(options: LogFilter.allCases.map { ($0, $0.label) },
                         selection: $filter)
            lines
            HStack(spacing: 8) {
                Button("Copy") { copy() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(shown.isEmpty)
                Button("Show in Finder") { reveal() }
                    .buttonStyle(PillButtonStyle())
                Button("Clear") { log.clear() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(log.entries.isEmpty)
                Spacer()
                Text(shown.count == 1 ? "1 line" : "\(shown.count) lines")
                    .font(Theme.small.monospacedDigit())
                    .foregroundStyle(Theme.textDim)
            }
            Text("Every line also goes to ~/Library/Logs/M0110HUD/M0110HUD.log, which "
                 + "keeps what came before this launch. Clearing empties this list, "
                 + "not\u{00A0}the\u{00A0}file.")
                .font(Theme.small)
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lines: some View {
        let shown = self.shown
        return Group {
            if shown.isEmpty {
                Text("Nothing logged yet.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot {
                // `ImageRenderer` cannot size a ScrollView; the newest lines
                // stand in for the scrolled-to-the-bottom list.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(shown.suffix(24)) { row($0) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(shown) { row($0).id($0.id) }
                        }
                        .padding(10)
                    }
                    .onAppear { proxy.scrollTo(shown.last?.id, anchor: .bottom) }
                    .onChange(of: shown.last?.id) { id in
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 380)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.key))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Theme.keyStroke.opacity(0.4), lineWidth: 1))
    }

    private func row(_ entry: DebugLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DebugLog.clock.string(from: entry.date))
                .foregroundStyle(Theme.textDim)
            Text(entry.source.rawValue)
                .foregroundStyle(Self.tint(entry.source))
                .frame(width: 66, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled)
    }

    /// Fixed rather than dynamic: the panel is dark in either appearance, and
    /// `accentPale`'s dark variant all but vanishes on it.
    private static func tint(_ source: DebugLog.Source) -> Color {
        switch source {
        case .app: return Theme.accent
        case .bluetooth: return Color(red: 0.62, green: 0.72, blue: 0.98)
        case .clipboard: return Theme.good
        case .studio: return Theme.warn
        }
    }

    /// The lines showing, in the file's format, ready to paste into an issue.
    private func copy() {
        let text = shown.map(\.line).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func reveal() {
        guard let file = log.file else { return }
        log.flush()
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent().deletingLastPathComponent())
        }
    }
}
