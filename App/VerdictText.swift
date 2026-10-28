import StraylightKit

extension Verdict {
    /// The verdict in words, for the popover header and VoiceOver (PRD §6.3).
    var title: String {
        switch self {
        case .measuring: String(localized: "Measuring")
        case .good: String(localized: "Good")
        case .internetProblem: String(localized: "Internet problem")
        case .internetDown: String(localized: "Internet down")
        case .localProblem: String(localized: "Local network problem")
        case .localDown: String(localized: "Local network down")
        case .connectionProblem: String(localized: "Connection problem")
        case .connectionDown: String(localized: "Connection down")
        case .internetUnmeasured: String(localized: "Can't measure the internet")
        case .offline: String(localized: "Offline")
        }
    }
}
