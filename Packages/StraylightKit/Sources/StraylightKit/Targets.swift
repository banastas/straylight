/// Which hosts to probe (PRD §6.1). Defaults match §6.10.
public struct TargetSettings: Equatable, Sendable {
    /// Primary first. A second host from another provider is optional.
    public var internetHosts: [String] = ["1.1.1.1", "8.8.8.8"]
    /// Also probe the primary internet host over IPv6 on dual-stack networks.
    public var probeIPv6 = true
    /// Up to two.
    public var customHosts: [String] = []

    public init() {}
}

public enum TargetRole: Hashable, Sendable, CustomStringConvertible {
    case router
    /// An index into `TargetSettings.internetHosts`.
    case internet(Int)
    /// The primary internet host over IPv6, on dual-stack networks only.
    case internetIPv6
    /// An index into `TargetSettings.customHosts`.
    case custom(Int)

    public var isInternet: Bool {
        switch self {
        case .internet, .internetIPv6: true
        case .router, .custom: false
        }
    }

    /// Parses `description`, as stored in the history database.
    public init?(_ description: String) {
        switch description {
        case "router": self = .router
        case "internet-ipv6": self = .internetIPv6
        default:
            let parts = description.split(whereSeparator: { "[]".contains($0) })
            guard parts.count == 2, let index = Int(parts[1]) else { return nil }
            switch parts[0] {
            case "internet": self = .internet(index)
            case "custom": self = .custom(index)
            default: return nil
            }
        }
    }

    /// Plan order: router, internet hosts, the primary host over IPv6, custom targets.
    var rank: Int {
        switch self {
        case .router: 0
        case .internet(let index): 1 + index
        case .internetIPv6: 3
        case .custom(let index): 4 + index
        }
    }

    public var description: String {
        switch self {
        case .router: "router"
        case .internet(let index): "internet[\(index)]"
        case .internetIPv6: "internet-ipv6"
        case .custom(let index): "custom[\(index)]"
        }
    }
}

public struct Target: Equatable, Sendable {
    public let role: TargetRole
    /// As configured, or "router".
    public let host: String
    public let address: ProbeAddress
}

public enum TargetPlan {
    /// IPv6 addresses of the preset internet hosts, for IPv6-only and dual-stack networks.
    static let ipv6Equivalents = [
        "1.1.1.1": "2606:4700:4700::1111",
        "8.8.8.8": "2001:4860:4860::8888",
        "9.9.9.9": "2620:fe::fe",
    ]

    /// The targets for a path. IPv4 is used whenever the network has it; an
    /// IPv6-only network uses IPv6 throughout (PRD §6.1). Hostnames go through
    /// `resolve`, which blocks, so call this off the main thread.
    public static func targets(
        for path: NetworkPath,
        settings: TargetSettings,
        resolve: (String) -> [ProbeAddress] = ProbeAddress.resolve
    ) -> [Target] {
        guard path.isSatisfied else { return [] }
        let family: IPFamily = path.hasIPv4 ? .v4 : .v6
        var targets: [Target] = []

        if let router = family == .v4 ? path.routerIPv4 : path.routerIPv6 {
            targets.append(Target(role: .router, host: "router", address: router))
        }
        for (index, host) in settings.internetHosts.prefix(2).enumerated() {
            if let address = address(of: host, family: family, resolve: resolve) {
                targets.append(Target(role: .internet(index), host: host, address: address))
            }
        }
        if path.hasIPv4, path.hasIPv6, settings.probeIPv6, let host = settings.internetHosts.first,
           let address = address(of: host, family: .v6, resolve: resolve) {
            targets.append(Target(role: .internetIPv6, host: host, address: address))
        }
        for (index, host) in settings.customHosts.prefix(2).enumerated() {
            // A custom host may only have the other family; use it if the network has it.
            let other: IPFamily = family == .v4 ? .v6 : .v4
            let otherAvailable = other == .v4 ? path.hasIPv4 : path.hasIPv6
            if let address = address(of: host, family: family, resolve: resolve)
                ?? (otherAvailable ? address(of: host, family: other, resolve: resolve) : nil) {
                targets.append(Target(role: .custom(index), host: host, address: address))
            }
        }
        return targets
    }

    static func address(of host: String, family: IPFamily, resolve: (String) -> [ProbeAddress]) -> ProbeAddress? {
        if let numeric = ProbeAddress(host) {
            if numeric.family == family { return numeric }
            return family == .v6 ? ipv6Equivalents[host].flatMap { ProbeAddress($0) } : nil
        }
        return resolve(host).first { $0.family == family }
    }
}

/// How a target is being probed, decided during warm-up and kept until the
/// next network change (PRD §6.1, §6.2).
public enum TargetStatus: Equatable, Sendable {
    case warmingUp
    case icmp
    /// The host drops ICMP but accepts TCP, so it's timed with TCP connects.
    case tcp
    /// A router that answered no ping during warm-up. Its card is hidden.
    case doesntAnswerPing
    /// The router can't be reached because the VPN blocks local traffic.
    case unreachableVPN

    /// What the target is measured with; nil when it isn't measured.
    public var measuredProtocol: ProbeEngine.ProbeProtocol? {
        switch self {
        case .warmingUp, .icmp: .icmp
        case .tcp: .tcp
        case .doesntAnswerPing, .unreachableVPN: nil
        }
    }
}

/// The warm-up and fallback rules for one target, without sockets or timers so
/// they can be tested. `ProbeEngine` feeds it what it sends and receives.
struct TargetTracker {
    static let warmUpDuration = 10.0
    /// Without ICMP replies by this point, internet hosts also try TCP.
    static let tcpCheckAfter = 3.0
    /// In TCP mode, and for a router that doesn't answer, ICMP is retried this often.
    static let recheckInterval = 60.0
    /// ICMP replies in a row that end TCP mode.
    static let repliesToLeaveTCP = 3
    /// Replies in a row that end a fast recheck.
    static let repliesToEndRecheck = 3
    /// A probe counts as due this much before its interval is up, so a 5 s
    /// target probed on 1 s ticks isn't pushed to the 6th tick by timer leeway.
    static let dueTolerance = 0.5

    let target: Target
    let isVPN: Bool
    let startedAt: Double
    private(set) var status = TargetStatus.warmingUp
    private(set) var icmpReplies = 0
    private(set) var tcpReplies = 0
    private var consecutiveICMPReplies = 0
    /// Probing every second after a lost probe, until 3 replies in a row (PRD §6.2).
    private(set) var isRechecking = false
    private var recheckReplies = 0
    private var lastSent: Double?

    init(target: Target, isVPN: Bool, now: Double) {
        self.target = target
        self.isVPN = isVPN
        startedAt = now
    }

    /// What to send this tick.
    struct Sends: Equatable {
        var icmp = false
        var tcp = false
        /// True when the ICMP probe only checks whether ICMP works again, so its
        /// result isn't a measurement.
        var icmpIsCheck = false
        /// True when the TCP probe only checks whether TCP works (warm-up).
        var tcpIsCheck = false
    }

    /// - Parameters:
    ///   - interval: seconds between measurements outside warm-up and fast recheck.
    ///   - routerAnswered: whether the router has replied to ICMP since the network change.
    ///   - sinceLastCheck: seconds since this target's last ICMP check, in TCP mode or while the router doesn't answer.
    func sends(now: Double, interval: Double, routerAnswered: Bool, sinceLastCheck: Double) -> Sends {
        let isDue = isRechecking || now - (lastSent ?? -.infinity) >= interval - Self.dueTolerance
        switch status {
        case .warmingUp:
            let tryTCP = target.role.isInternet && icmpReplies == 0 && routerAnswered && now - startedAt >= Self.tcpCheckAfter
            return Sends(icmp: true, tcp: tryTCP, tcpIsCheck: tryTCP)
        case .icmp:
            return Sends(icmp: isDue)
        case .tcp:
            return Sends(icmp: sinceLastCheck >= Self.recheckInterval, tcp: isDue, icmpIsCheck: true)
        case .doesntAnswerPing, .unreachableVPN:
            return Sends(icmp: sinceLastCheck >= Self.recheckInterval, icmpIsCheck: true)
        }
    }

    /// Whether this target needs the 1 s tick.
    var needsFastTicks: Bool {
        status == .warmingUp || isRechecking
    }

    /// Records that a measurement probe went out.
    mutating func didSend(now: Double) {
        lastSent = now
    }

    /// Records a measurement's outcome, for fast recheck. Check probes don't count.
    mutating func recordMeasurement(replied: Bool, interval: Double) {
        if !replied {
            isRechecking = interval > 1
            recheckReplies = 0
        } else if isRechecking {
            recheckReplies += 1
            if recheckReplies >= Self.repliesToEndRecheck { isRechecking = false }
        }
    }

    /// Records an ICMP outcome. Returns the new status when it changes.
    mutating func recordICMP(replied: Bool) -> TargetStatus? {
        if replied { icmpReplies += 1 }
        consecutiveICMPReplies = replied ? consecutiveICMPReplies + 1 : 0
        switch status {
        case .tcp where consecutiveICMPReplies >= Self.repliesToLeaveTCP,
             .doesntAnswerPing where replied,
             .unreachableVPN where replied:
            setStatus(.icmp)
            return status
        default:
            return nil
        }
    }

    mutating func recordTCP(replied: Bool) {
        if replied { tcpReplies += 1 }
    }

    /// Ends warm-up once it has run its course. Returns the new status when it changes.
    mutating func finishWarmUpIfDue(now: Double) -> TargetStatus? {
        guard status == .warmingUp, now - startedAt >= Self.warmUpDuration else { return nil }
        if icmpReplies > 0 {
            setStatus(.icmp)
        } else if target.role == .router {
            setStatus(isVPN ? .unreachableVPN : .doesntAnswerPing)
        } else if target.role.isInternet, tcpReplies > 0 {
            // TCP works where ICMP doesn't. ICMP failing alone is an outage, not a reason to switch.
            setStatus(.tcp)
        } else {
            setStatus(.icmp)
        }
        return status
    }

    /// A fast recheck carries on past the end of warm-up, but not into another protocol.
    private mutating func setStatus(_ status: TargetStatus) {
        if status.measuredProtocol != self.status.measuredProtocol {
            isRechecking = false
            recheckReplies = 0
        }
        self.status = status
    }
}
