import AppKit
import StraylightKit
import SwiftUI

/// Kept between openings, so the popover reopens where it was left.
@MainActor
@Observable
final class PopoverState {
    var showingSettings = false
    var chartRange = ChartRange.hour
    var chartTarget = ChartTarget.internet
    /// The first-run note (PRD §6.8), until it's dismissed.
    var showingFirstRun = false
}

enum ChartTarget: String, CaseIterable, Identifiable {
    case internet, router
    var id: Self { self }
    var role: TargetRole { self == .router ? .router : .internet(0) }
}

/// What the popover asks of the app; the popover itself is released on close.
@MainActor
struct PopoverActions {
    var export: (CSVExport.Kind, CSVExport.Range) -> Void
    var copyDiagnostics: () async -> Void
    var dismissFirstRun: () -> Void
}

extension EnvironmentValues {
    @Entry var accent: Color = Accent.phosphor.color
}

struct PopoverView: View {
    let model: AppModel
    @Bindable var preferences: Preferences
    @Bindable var state: PopoverState
    let actions: PopoverActions
    @State private var contentHeight: CGFloat = 0

    /// Taller content scrolls instead of running off the screen.
    private var maxScrollHeight: CGFloat {
        max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 180)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(model: model)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if state.showingSettings {
                        SettingsView(preferences: preferences)
                    } else {
                        if state.showingFirstRun {
                            FirstRunCard(dismiss: actions.dismissFirstRun)
                        }
                        cards
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(contentHeight, maxScrollHeight))
            FooterView(state: state, actions: actions)
        }
        .padding(14)
        .frame(width: 340)
        // The default popover glass lets busy windows show through the numbers.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .fontDesign(.monospaced)
        .tint(preferences.accent.color)
        .environment(\.accent, preferences.accent.color)
        .transaction { $0.animation = nil }
    }

    @ViewBuilder private var cards: some View {
        let snapshot = model.snapshot
        if snapshot.verdict == .offline, !model.isPaused {
            OfflineCard(since: model.offlineSince)
        } else {
            Group {
                RouterCard(model: model)
                InternetCard(model: model)
                ForEach(snapshot.targets.filter { if case .custom = $0.target.role { true } else { false } }, id: \.target.role) { target in
                    CustomTargetCard(model: model, target: target)
                }
            }
            .opacity(model.isPaused ? 0.5 : 1)
        }
        HistoryCard(model: model, state: state)
        if snapshot.path.kind == .wifi || model.wifi != nil {
            WiFiCard(info: model.wifi)
        }
        EventsCard(model: model, export: actions.export)
    }
}

// MARK: - Header

private struct HeaderView: View {
    let model: AppModel
    @Environment(\.accent) private var accent

    var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                Spacer()
                if model.isPaused {
                    Button("resume") { model.resume() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if let detail = model.isPaused ? nil : snapshot.verdictDetail(offlineSince: model.offlineSince) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.path.isSatisfied {
                HStack(spacing: 6) {
                    Text(pathLine)
                        .foregroundStyle(.secondary)
                    if snapshot.path.isVPN { Badge(text: String(localized: "via VPN")) }
                    if snapshot.ipv6Problem { Badge(text: String(localized: "IPv6 problem"), color: .orange) }
                }
                .font(.caption2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if let until = model.pausedUntil {
            return String(localized: "Paused until \(until.formatted(date: .omitted, time: .shortened))")
        }
        return model.snapshot.verdict.title
    }

    private var symbol: String {
        if model.isPaused { return "pause.circle" }
        switch model.snapshot.verdict {
        case .measuring: return "ellipsis.circle"
        case .good: return "checkmark.circle"
        case .internetProblem, .localProblem, .connectionProblem, .internetUnmeasured: return "exclamationmark.triangle"
        case .internetDown, .localDown, .connectionDown: return "xmark.octagon"
        case .offline: return "wifi.slash"
        }
    }

    private var color: Color {
        if model.isPaused { return .secondary }
        switch model.snapshot.verdict {
        case .measuring, .offline: return .secondary
        case .good: return accent
        case .internetProblem, .localProblem, .connectionProblem, .internetUnmeasured: return .orange
        case .internetDown, .localDown, .connectionDown: return .red
        }
    }

    /// "Wi‑Fi · 192.168.20.34 · router 192.168.20.1"
    private var pathLine: String {
        let path = model.snapshot.path
        var parts = [path.kind.title]
        if let address = model.localAddress { parts.append(address) }
        if let router = path.routerIPv4 ?? path.routerIPv6 {
            parts.append(String(localized: "router \(router.description)"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Footer

private struct FooterView: View {
    @Bindable var state: PopoverState
    let actions: PopoverActions
    @State private var copy = CopyState.idle

    private enum CopyState {
        case idle, copying, copied
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                state.showingSettings.toggle()
            } label: {
                Label(state.showingSettings ? String(localized: "done") : String(localized: "settings"),
                      systemImage: state.showingSettings ? "chevron.left" : "gearshape")
            }
            .keyboardShortcut(",")
            Button {
                Task {
                    // Reading the log takes a few seconds.
                    copy = .copying
                    await actions.copyDiagnostics()
                    copy = .copied
                    try? await Task.sleep(for: .seconds(2))
                    copy = .idle
                }
            } label: {
                switch copy {
                case .idle: Label(String(localized: "diagnostics"), systemImage: "doc.on.doc")
                case .copying: Label(String(localized: "copying…"), systemImage: "hourglass")
                case .copied: Label(String(localized: "copied"), systemImage: "checkmark")
                }
            }
            .disabled(copy == .copying)
            .help(String(localized: "Copy diagnostics to the clipboard"))
            .accessibilityLabel(copy == .copied ? String(localized: "Diagnostics copied") : String(localized: "Copy diagnostics"))
            Text("v\(version)")
                .foregroundStyle(.tertiary)
            Spacer()
            Button(String(localized: "quit")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

// MARK: - Shared pieces

/// Card chrome, as in flatline: title, optional subtitle and headline value, content.
struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    var value: String?
    var valueLabel: String?
    @ViewBuilder var content: Content
    @Environment(\.accent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(accent)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let value {
                    Text(value)
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                        .accessibilityLabel(valueLabel ?? value)
                }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(contrast == .increased ? 0.7 : 0.18)))
    }
}

/// A small label and value, read by VoiceOver as one phrase.
struct Stat: View {
    let label: String
    let value: String
    var spoken: String?

    var body: some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(spoken ?? value)")
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

extension NetworkPath.Kind {
    var title: String {
        switch self {
        case .wifi: String(localized: "Wi‑Fi")
        case .ethernet: String(localized: "Ethernet")
        case .cellular: String(localized: "Cellular")
        case .other: String(localized: "Other")
        }
    }
}
