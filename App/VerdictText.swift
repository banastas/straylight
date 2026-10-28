import Foundation
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

extension MonitorSnapshot {
    /// The line under the verdict: what's wrong and where (PRD §6.7), for
    /// example "Router is fine; 8% loss to 1.1.1.1 and 8.8.8.8".
    func verdictDetail(offlineSince: Date?) -> String? {
        let router = self[.router]
        let routerMeasured = router?.status.measuredProtocol != nil
        let hosts = countedInternetHosts
        let summary = ProblemSummary.of(hosts).map(\.text)
        switch verdict {
        case .measuring:
            return String(localized: "The first verdict comes after 10 seconds of probes.")
        case .good:
            guard routerMeasured else { return String(localized: "The internet is fine. The router can't be measured.") }
            if router?.state.isBadOrDown == true { return String(localized: "The internet is fine. The router is slow to answer ping.") }
            return String(localized: "Router and internet are fine.")
        case .internetProblem:
            return String(localized: "Router is fine; \(summary ?? String(localized: "trouble beyond it")).")
        case .internetDown:
            return String(localized: "Router is fine, but no internet host answers.")
        case .localProblem:
            let place = path.kind == .wifi ? String(localized: "Wi‑Fi or the router") : String(localized: "The local network or the router")
            let routerSummary = router.flatMap { ProblemSummary.of([$0]) }.map(\.text)
            return routerSummary.map { String(localized: "\(place): \($0).") } ?? "\(place)."
        case .localDown:
            return String(localized: "Can't reach the router.")
        case .connectionProblem:
            return String(localized: "\(summary ?? String(localized: "Trouble on the way to the internet")). The router can't be measured, so local and internet trouble can't be told apart.")
        case .connectionDown:
            return String(localized: "No internet host answers. The router can't be measured, so local and internet trouble can't be told apart.")
        case .internetUnmeasured:
            if targets.contains(where: \.answeredLocally) {
                return String(localized: "Something on the local network answers for the internet hosts.")
            }
            return String(localized: "The internet hosts couldn't be resolved.")
        case .offline:
            guard let offlineSince else { return String(localized: "No network.") }
            return String(localized: "No network since \(PopoverFormat.time(offlineSince)).")
        }
    }
}

extension ProblemSummary {
    /// "8% loss to 1.1.1.1 and 8.8.8.8", "slow replies from the router (p95 210 ms)"
    var text: String {
        let names = hosts.map { $0 == "router" ? String(localized: "the router") : $0 }.formatted(.list(type: .and))
        switch kind {
        case .loss: return String(localized: "\(PopoverFormat.percent(value)) loss to \(names)")
        case .latency: return String(localized: "slow replies from \(names) (p95 \(PopoverFormat.rtt(value)))")
        case .jitter: return String(localized: "\(PopoverFormat.rtt(value)) jitter to \(names)")
        }
    }
}

/// Number formats shared by the popover.
enum PopoverFormat {
    /// "5.4 ms", "23 ms", "1.2 s", "—"
    static func rtt(_ milliseconds: Double?) -> String {
        let text = MenuBarText.rtt(milliseconds)
        guard text != "—" else { return text }
        return text.hasSuffix("ms") ? text.dropLast(2) + " ms" : text.dropLast() + " s"
    }

    /// For VoiceOver: "5.4 milliseconds".
    static func spokenRTT(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return String(localized: "no value") }
        let value = milliseconds < 9.95 ? milliseconds.formatted(.number.precision(.fractionLength(1))) : milliseconds.formatted(.number.precision(.fractionLength(0)))
        return String(localized: "\(value) milliseconds")
    }

    /// "0%", "1.7%", "12%"
    static func percent(_ value: Double) -> String {
        if value == 0 { return "0%" }
        return value < 9.95 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }

    /// "14:32" today, "Oct 27, 14:32" before.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// "16s", "2m 5s", "1h 3m"
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(1, seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}
