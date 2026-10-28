import ServiceManagement
import StraylightKit
import SwiftUI

struct WiFiCard: View {
    let info: WiFiInfo?

    var body: some View {
        Card(title: String(localized: "WI‑FI"), value: info.map { "\($0.rssi) dBm" } ?? "—",
             valueLabel: info.map { String(localized: "signal \($0.rssi) dBm") }) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Stat(label: String(localized: "noise"), value: info.map { "\($0.noise) dBm" } ?? "—")
                    Stat(label: String(localized: "snr"), value: info?.snr.map { "\($0) dB" } ?? "—",
                         spoken: info?.snr.map { String(localized: "signal to noise \($0) dB") })
                }
                GridRow {
                    Stat(label: String(localized: "rate"), value: info.map { "\(Int($0.transmitRate.rounded())) Mbit/s" } ?? "—")
                    Stat(label: String(localized: "band"), value: band)
                }
            }
            .font(.caption)
        }
    }

    /// "5 GHz · ch 36 · 80 MHz"
    private var band: String {
        guard let info else { return "—" }
        var parts: [String] = []
        if let band = info.band { parts.append(band) }
        if let channel = info.channel { parts.append(String(localized: "ch \(channel)")) }
        if let width = info.width { parts.append("\(width) MHz") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// The last 10 outages and spikes, with CSV export.
struct EventsCard: View {
    let model: AppModel
    let export: (CSVExport.Kind, CSVExport.Range) -> Void
    @State private var events: [NetworkEvent] = []
    @Environment(\.accent) private var accent

    var body: some View {
        Card(title: String(localized: "EVENTS")) {
            if events.isEmpty {
                Text(String(localized: "No outages or spikes"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                EventRow(event: event)
            }
            Menu {
                Section(String(localized: "Measurements")) {
                    ForEach(CSVExport.Range.allCases) { range in
                        Button(range.title) { export(.aggregates, range) }
                    }
                }
                Section(String(localized: "Events")) {
                    ForEach(CSVExport.Range.allCases) { range in
                        Button(range.title) { export(.events, range) }
                    }
                }
            } label: {
                Label(String(localized: "export csv"), systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
        }
        // Reloaded whenever a new event arrives while open.
        .task(id: model.recentEvents.last?.end) {
            if let loaded = await model.readHistory({ try $0.latestEvents(limit: 10) }) {
                events = loaded
            }
        }
    }
}

private struct EventRow: View {
    let event: NetworkEvent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: event.kind == .outage ? "xmark.circle" : "arrow.up.right")
                .foregroundStyle(event.kind == .outage ? .red : .orange)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(event.kind == .outage ? String(localized: "outage") : String(localized: "spike"))
                .frame(width: 44, alignment: .leading)
            Text(event.host == "router" ? String(localized: "router") : event.host)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let worst = event.worstRTT {
                Text(PopoverFormat.rtt(worst)).foregroundStyle(.secondary)
            }
            Text(PopoverFormat.duration(event.duration))
                .monospacedDigit()
            Text(PopoverFormat.time(event.start))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        let kind = event.kind == .outage ? String(localized: "Outage") : String(localized: "Spike")
        let host = event.host == "router" ? String(localized: "router") : event.host
        var text = String(localized: "\(kind) to \(host) at \(PopoverFormat.time(event.start)), \(PopoverFormat.duration(event.duration))")
        if let worst = event.worstRTT { text += String(localized: ", worst \(PopoverFormat.spokenRTT(worst))") }
        return text
    }
}

/// The first-run note (PRD §6.8).
struct FirstRunCard: View {
    let dismiss: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Card(title: String(localized: "WELCOME")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "straylight sends small pings about once a second to your router, 1.1.1.1 (Cloudflare) and 8.8.8.8 (Google), and times the replies. Nothing else leaves your Mac, and history stays on it."))
                Text(String(localized: "The targets can be changed in settings."))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            LaunchAtLoginToggle(isOn: $launchAtLogin, error: $loginError)
            HStack {
                Spacer()
                Button(String(localized: "Got it"), action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
    }
}
