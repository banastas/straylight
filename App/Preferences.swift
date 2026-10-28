import Foundation
import Observation
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

/// User settings, persisted to `UserDefaults` (PRD §6.10). The popover's
/// settings panel has the ones that exist so far; M7 adds the rest.
@MainActor
@Observable
final class Preferences {
    static let intervals: [Double] = [0.5, 1, 2, 5]

    var displayStyle: DisplayStyle { didSet { save(displayStyle.rawValue, "displayStyle") } }
    var menuBarTarget: MenuBarTarget { didSet { save(menuBarTarget.rawValue, "menuBarTarget") } }
    /// Seconds between probes on power.
    var interval: Double { didSet { save(interval, "interval") } }
    var accent: Accent { didSet { save(accent.rawValue, "accent") } }
    /// The first-run note has been shown (PRD §6.8).
    var didShowFirstRun: Bool { didSet { save(didShowFirstRun, "didShowFirstRun") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["interval": 1.0])
        displayStyle = Self.load(defaults, "displayStyle", .textAndTrace)
        menuBarTarget = Self.load(defaults, "menuBarTarget", .internet)
        interval = defaults.double(forKey: "interval")
        accent = Self.load(defaults, "accent", .phosphor)
        didShowFirstRun = defaults.bool(forKey: "didShowFirstRun")
    }

    private func save(_ value: some Sendable, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private static func load<T: RawRepresentable<String>>(_ defaults: UserDefaults, _ key: String, _ fallback: T) -> T {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }
}
