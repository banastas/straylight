import Foundation
import Observation

enum DisplayStyle: String, CaseIterable, Identifiable {
    case text, trace, textAndTrace
    var id: Self { self }
}

enum MenuBarTarget: String, CaseIterable, Identifiable {
    case internet, router, both
    var id: Self { self }
}

/// User settings, persisted to `UserDefaults` (PRD §6.10). The settings panel
/// comes with the popover; until then they can be set with `defaults write`.
@MainActor
@Observable
final class Preferences {
    var displayStyle: DisplayStyle { didSet { save(displayStyle.rawValue, "displayStyle") } }
    var menuBarTarget: MenuBarTarget { didSet { save(menuBarTarget.rawValue, "menuBarTarget") } }
    /// Seconds between probes on power.
    var interval: Double { didSet { save(interval, "interval") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["interval": 1.0])
        displayStyle = Self.load(defaults, "displayStyle", .textAndTrace)
        menuBarTarget = Self.load(defaults, "menuBarTarget", .internet)
        interval = defaults.double(forKey: "interval")
    }

    private func save(_ value: some Sendable, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private static func load<T: RawRepresentable<String>>(_ defaults: UserDefaults, _ key: String, _ fallback: T) -> T {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }
}
