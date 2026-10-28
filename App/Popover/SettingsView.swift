import ServiceManagement
import StraylightKit
import SwiftUI

/// The inline settings panel (PRD §6.10).
struct SettingsView: View {
    @Bindable var preferences: Preferences
    let model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSection(title: String(localized: "MENU BAR")) {
                Row(String(localized: "show")) {
                    Picker(String(localized: "show"), selection: $preferences.menuBarTarget) {
                        Text(String(localized: "internet")).tag(MenuBarTarget.internet)
                        Text(String(localized: "router")).tag(MenuBarTarget.router)
                        Text(String(localized: "both")).tag(MenuBarTarget.both)
                    }
                }
                Row(String(localized: "style")) {
                    Picker(String(localized: "style"), selection: $preferences.displayStyle) {
                        Text(String(localized: "text")).tag(DisplayStyle.text)
                        Text(String(localized: "trace")).tag(DisplayStyle.trace)
                        Text(String(localized: "both")).tag(DisplayStyle.textAndTrace)
                    }
                }
            }
            SettingsSection(title: String(localized: "PROBING")) {
                Row(String(localized: "on power")) {
                    Picker(String(localized: "on power"), selection: $preferences.interval) {
                        ForEach(Preferences.intervals, id: \.self) { Text(Self.seconds($0)).tag($0) }
                    }
                }
                Row(String(localized: "on battery")) {
                    Picker(String(localized: "on battery"), selection: $preferences.batteryInterval) {
                        ForEach(Preferences.batteryIntervals, id: \.self) { Text(Self.seconds($0)).tag($0) }
                    }
                }
                Hint(text: slowRateText)
                Toggle(String(localized: "IPv6 on dual-stack networks"), isOn: $preferences.probeIPv6)
                Toggle(String(localized: "keep monitoring while locked"), isOn: $preferences.keepMonitoringWhileLocked)
                Hint(text: String(localized: "For overnight logging. Otherwise probing stops while the screen is locked."))
            }
            SettingsSection(title: String(localized: "TARGETS")) {
                Row(String(localized: "internet")) {
                    HostPicker(host: $preferences.primaryHost, allowsOff: false)
                }
                Row(String(localized: "second")) {
                    HostPicker(host: $preferences.secondaryHost, allowsOff: true)
                }
                Hint(text: String(localized: "Pick hosts from different providers, so one provider's bad day doesn't look like your ISP's."))
                ForEach(0..<Preferences.maxCustomHosts, id: \.self) { index in
                    Row(index == 0 ? String(localized: "custom") : "") {
                        HostField(host: customHost(index), prompt: String(localized: "host or IP, optional"))
                    }
                }
                Hint(text: String(localized: "Custom targets get their own cards and history, and don't affect the verdict."))
            }
            SettingsSection(title: String(localized: "HISTORY")) {
                Row(String(localized: "keep")) {
                    Picker(String(localized: "keep"), selection: $preferences.retentionDays) {
                        ForEach(Preferences.retentionOptions, id: \.self) { Text("\($0)d").tag($0) }
                    }
                }
                Hint(text: String(localized: "Per-minute detail is kept for 7 days, hourly after that."))
            }
            SettingsSection(title: String(localized: "NOTIFICATIONS")) {
                Toggle(String(localized: "internet outages"), isOn: $preferences.notifyOutages)
                Toggle(String(localized: "verdict changes"), isOn: $preferences.notifyVerdictChanges)
                if model.notificationsDenied {
                    Hint(text: String(localized: "Notifications are turned off for straylight in System Settings."), color: .orange)
                } else {
                    Hint(text: String(localized: "Outages after 10 seconds and when they end; verdicts that hold for 30 seconds."))
                }
            }
            SettingsSection(title: String(localized: "GENERAL")) {
                Row(String(localized: "accent")) {
                    HStack(spacing: 8) {
                        ForEach(Accent.allCases) { option in
                            Button {
                                preferences.accent = option
                            } label: {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: preferences.accent == option ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.rawValue)
                            .accessibilityAddTraits(preferences.accent == option ? .isSelected : [])
                        }
                    }
                }
                LaunchAtLoginToggle(isOn: $launchAtLogin, error: $loginError)
            }
        }
        .font(.caption)
        .pickerStyle(.segmented)
        .toggleStyle(TrailingSwitch())
        .controlSize(.small)
    }

    private static func seconds(_ interval: Double) -> String {
        interval < 1 ? "½s" : "\(Int(interval))s"
    }

    private var slowRateText: String {
        switch model.slowRateReason {
        case nil: String(localized: "The battery interval also applies in Low Power Mode, and on Low Data or hotspot networks.")
        case .battery: String(localized: "On battery now, so probing every \(Self.seconds(preferences.batteryInterval)).")
        case .lowPowerMode: String(localized: "Low Power Mode is on, so probing every \(Self.seconds(preferences.batteryInterval)).")
        case .lowDataMode: String(localized: "This network is in Low Data Mode, so probing every \(Self.seconds(preferences.batteryInterval)).")
        case .expensivePath: String(localized: "This network is a hotspot or metered, so probing every \(Self.seconds(preferences.batteryInterval)).")
        }
    }

    private func customHost(_ index: Int) -> Binding<String> {
        Binding {
            index < preferences.customHosts.count ? preferences.customHosts[index] : ""
        } set: { host in
            var hosts = preferences.customHosts
            while hosts.count <= index { hosts.append("") }
            hosts[index] = host
            while hosts.last == "" { hosts.removeLast() }
            preferences.customHosts = hosts
        }
    }
}

/// An internet host: one of the usual ones, off, or any other host typed in.
private struct HostPicker: View {
    @Binding var host: String
    let allowsOff: Bool
    @State private var choice = ""
    private static let other = "other"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(String(localized: "host"), selection: $choice) {
                ForEach(Preferences.knownHosts, id: \.self) { Text($0).tag($0) }
                if allowsOff { Text(String(localized: "off")).tag("") }
                Text(String(localized: "other…")).tag(Self.other)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: choice) { _, choice in
                if choice != Self.other { host = choice }
            }
            if choice == Self.other {
                HostField(host: $host, prompt: String(localized: "host or IP"))
            }
        }
        .onAppear {
            let known = Preferences.knownHosts.contains(host) || (allowsOff && host.isEmpty)
            choice = known ? host : Self.other
        }
    }
}

/// A host typed in, applied on Return or when the field loses focus, so
/// targets aren't re-resolved on every keystroke.
private struct HostField: View {
    @Binding var host: String
    let prompt: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $draft, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, focused in if !focused { commit() } }
            .onAppear { draft = host }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let cleaned = Preferences.clean(draft) ?? ""
        if cleaned != host { host = cleaned }
    }
}

/// The label on the left and the switch on the right edge, lined up down the panel.
struct TrailingSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct Hint: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct LaunchAtLoginToggle: View {
    @Binding var isOn: Bool
    @Binding var error: String?

    var body: some View {
        Toggle(String(localized: "launch at login"), isOn: $isOn)
            .toggleStyle(TrailingSwitch())
            .controlSize(.small)
            .font(.caption)
            .onChange(of: isOn) { _, enabled in set(enabled) }
        if let error {
            Text(error).font(.caption2).foregroundStyle(.red)
        }
    }

    private func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != isOn { isOn = actual }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(accent)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 76, alignment: .leading)
            content.labelsHidden()
        }
    }
}
