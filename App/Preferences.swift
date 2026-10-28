import Foundation
import Observation
import StraylightKit
import SwiftUI

enum DisplayStyle: String, CaseIterable, Identifiable {
    case text, trace, textAndTrace
    var id: Self { self }
}

enum MenuBarTarget: String, CaseIterable, Identifiable {
    case internet, router, both
    var id: Self { self }
}

/// The popover's accent, as in flatline. The menu bar stays monochrome.
enum Accent: String, CaseIterable, Identifiable {
    case phosphor, cyan, magenta, amber, system
    var id: Self { self }

    var color: Color {
        switch self {
        case .phosphor: Color(red: 0.20, green: 0.95, blue: 0.45)
        case .cyan: Color(red: 0.15, green: 0.85, blue: 1.00)
        case .magenta: Color(red: 1.00, green: 0.25, blue: 0.75)
        case .amber: Color(red: 1.00, green: 0.72, blue: 0.10)
        case .system: .accentColor
        }
    }
}

/// User settings, persisted to `UserDefaults` (PRD §6.10). Automatic updates
/// arrive with Sparkle (M9).
@MainActor
@Observable
final class Preferences {
    static let intervals: [Double] = [0.5, 1, 2, 5]
    static let batteryIntervals: [Double] = [1, 2, 5, 10]
    /// Offered for the internet hosts, besides any other host.
    static let knownHosts = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
    static let retentionOptions = [7, 30, 90]
    static let maxCustomHosts = 2

    var displayStyle: DisplayStyle { didSet { save(displayStyle.rawValue, "displayStyle") } }
    var menuBarTarget: MenuBarTarget { didSet { save(menuBarTarget.rawValue, "menuBarTarget") } }
    /// Seconds between probes on power.
    var interval: Double { didSet { save(interval, "interval") } }
    /// Seconds between probes on battery, in Low Power Mode, and on Low Data or expensive paths.
    var batteryInterval: Double { didSet { save(batteryInterval, "batteryInterval") } }
    var primaryHost: String { didSet { save(primaryHost, "primaryHost") } }
    /// Empty when off.
    var secondaryHost: String { didSet { save(secondaryHost, "secondaryHost") } }
    var probeIPv6: Bool { didSet { save(probeIPv6, "probeIPv6") } }
    /// Up to `maxCustomHosts`.
    var customHosts: [String] { didSet { save(customHosts, "customHosts") } }
    var keepMonitoringWhileLocked: Bool { didSet { save(keepMonitoringWhileLocked, "keepMonitoringWhileLocked") } }
    var retentionDays: Int { didSet { save(retentionDays, "retentionDays") } }
    var notifyOutages: Bool { didSet { save(notifyOutages, "notifyOutages") } }
    var notifyVerdictChanges: Bool { didSet { save(notifyVerdictChanges, "notifyVerdictChanges") } }
    var accent: Accent { didSet { save(accent.rawValue, "accent") } }
    /// The first-run note has been shown (PRD §6.8).
    var didShowFirstRun: Bool { didSet { save(didShowFirstRun, "didShowFirstRun") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "interval": 1.0, "batteryInterval": 5.0, "primaryHost": "1.1.1.1", "secondaryHost": "8.8.8.8",
            "probeIPv6": true, "retentionDays": 30,
        ])
        displayStyle = Self.load(defaults, "displayStyle", .textAndTrace)
        menuBarTarget = Self.load(defaults, "menuBarTarget", .internet)
        interval = defaults.double(forKey: "interval")
        batteryInterval = defaults.double(forKey: "batteryInterval")
        primaryHost = defaults.string(forKey: "primaryHost") ?? "1.1.1.1"
        secondaryHost = defaults.string(forKey: "secondaryHost") ?? ""
        probeIPv6 = defaults.bool(forKey: "probeIPv6")
        customHosts = defaults.stringArray(forKey: "customHosts") ?? []
        keepMonitoringWhileLocked = defaults.bool(forKey: "keepMonitoringWhileLocked")
        retentionDays = defaults.integer(forKey: "retentionDays")
        notifyOutages = defaults.bool(forKey: "notifyOutages")
        notifyVerdictChanges = defaults.bool(forKey: "notifyVerdictChanges")
        accent = Self.load(defaults, "accent", .phosphor)
        didShowFirstRun = defaults.bool(forKey: "didShowFirstRun")
    }

    /// What to probe. A secondary host the same as the primary is left out.
    var targetSettings: TargetSettings {
        var settings = TargetSettings()
        let primary = Self.clean(primaryHost) ?? "1.1.1.1"
        let secondary = Self.clean(secondaryHost)
        settings.internetHosts = secondary.map { $0 == primary ? [primary] : [primary, $0] } ?? [primary]
        settings.probeIPv6 = probeIPv6
        settings.customHosts = customHosts.compactMap(Self.clean).prefix(Self.maxCustomHosts).map(\.self)
        return settings
    }

    /// A host as typed, trimmed; nil when empty.
    static func clean(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func save(_ value: some Sendable, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private static func load<T: RawRepresentable<String>>(_ defaults: UserDefaults, _ key: String, _ fallback: T) -> T {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }
}
