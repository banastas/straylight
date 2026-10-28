/// What's wrong, for the popover header: "8% loss to 1.1.1.1 and 8.8.8.8"
/// (PRD §6.7). Loss matters most, then slow replies, then jitter; the value is
/// the worst among the targets that have that problem.
public struct ProblemSummary: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `value` is a percentage.
        case loss
        /// `value` is the p95 RTT in ms.
        case latency
        /// `value` is in ms.
        case jitter
    }

    public var kind: Kind
    public var value: Double
    /// Hosts as configured, in plan order.
    public var hosts: [String]

    public init(kind: Kind, value: Double, hosts: [String]) {
        self.kind = kind
        self.value = value
        self.hosts = hosts
    }

    /// The summary of `targets` that are Bad; nil when none is.
    public static func of(_ targets: [TargetSnapshot]) -> ProblemSummary? {
        let bad = targets.compactMap { target -> (TargetSnapshot, Problems)? in
            if case .bad(let problems) = target.state { (target, problems) } else { nil }
        }
        for (kind, problem) in [(Kind.loss, Problems.loss), (.latency, .latency), (.jitter, .jitter)] {
            let matching = bad.filter { $0.1.contains(problem) }.map(\.0)
            guard !matching.isEmpty else { continue }
            let values = matching.compactMap { target -> Double? in
                switch kind {
                case .loss: target.metrics.lossPercent
                case .latency: target.metrics.p95
                case .jitter: target.metrics.jitter
                }
            }
            return ProblemSummary(kind: kind, value: values.max() ?? 0, hosts: matching.map(\.target.host))
        }
        return nil
    }
}

extension MonitorSnapshot {
    /// The IPv4 internet hosts that count toward the verdict.
    public var countedInternetHosts: [TargetSnapshot] {
        targets.filter {
            if case .internet = $0.target.role { !$0.answeredLocally && $0.status.measuredProtocol != nil } else { false }
        }
    }
}
