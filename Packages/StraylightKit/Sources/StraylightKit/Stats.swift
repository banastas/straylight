import Foundation

/// A target's numbers over its window (PRD §6.3). RTTs are in milliseconds.
public struct Metrics: Equatable, Sendable {
    /// The latest reply.
    public var latest: Double?
    public var median: Double?
    public var p95: Double?
    /// Minimum RTT since the statistics last started over.
    public var baseline: Double?
    /// Mean |RTTᵢ − RTTᵢ₋₁| over consecutive replies, skipping pairs split by a loss.
    public var jitter: Double?
    public var sent = 0
    public var lost = 0
    /// Replies that came after the timeout. Already counted as lost.
    public var late = 0

    public init() {}

    public var lossPercent: Double {
        sent == 0 ? 0 : 100 * Double(lost) / Double(sent)
    }
}

/// A target's recent probes. The window is the last 60 s or the last 20
/// probes, whichever is longer. Times are seconds on any monotonic clock.
struct TargetStats {
    static let windowSeconds = 60.0
    static let windowProbes = 20

    struct Sample: Equatable {
        let time: Double
        /// nil when lost.
        let rtt: Double?
    }

    /// Oldest first, by send time.
    private(set) var samples: [Sample] = []
    private var lateTimes: [Double] = []
    private var baseline: Double?
    private var latest: Sample?

    /// RTTs of the replies in the window, oldest first.
    var replies: [Double] { samples.compactMap(\.rtt) }

    /// `time` is the probe's send time. A loss is only known at the timeout,
    /// after later probes may have replied, so samples are kept in send order.
    mutating func record(rtt: Double?, at time: Double) {
        let index = samples.lastIndex { $0.time <= time }.map { $0 + 1 } ?? 0
        samples.insert(Sample(time: time, rtt: rtt), at: index)
        if let rtt {
            baseline = min(baseline ?? rtt, rtt)
            if time >= latest?.time ?? -.infinity { latest = Sample(time: time, rtt: rtt) }
        }
        prune()
    }

    mutating func recordLate(at time: Double) {
        lateTimes.append(time)
        prune()
    }

    private mutating func prune() {
        guard let newest = samples.last?.time else { return }
        while samples.count > Self.windowProbes, newest - samples[0].time >= Self.windowSeconds {
            samples.removeFirst()
        }
        let oldest = samples[0].time
        lateTimes.removeAll { $0 < oldest }
    }

    var metrics: Metrics {
        var metrics = Metrics()
        let replies = replies
        let sorted = replies.sorted()
        metrics.latest = latest?.rtt
        metrics.median = Self.nearestRank(0.5, of: sorted)
        metrics.p95 = Self.nearestRank(0.95, of: sorted)
        metrics.baseline = baseline
        metrics.sent = samples.count
        metrics.lost = samples.count - replies.count
        metrics.late = lateTimes.count

        metrics.jitter = Self.jitter(samples)
        return metrics
    }

    /// Mean |RTTᵢ − RTTᵢ₋₁| over consecutive replies in send order, skipping
    /// pairs split by a loss. nil without two replies in a row.
    static func jitter(_ samples: [Sample]) -> Double? {
        var differences: [Double] = []
        for (previous, next) in zip(samples, samples.dropFirst()) {
            if let a = previous.rtt, let b = next.rtt { differences.append(abs(b - a)) }
        }
        return differences.isEmpty ? nil : differences.reduce(0, +) / Double(differences.count)
    }

    /// Nearest-rank percentile of an ascending list: over 60 values p95 is the
    /// 57th (the 4th-highest), over 20 the 19th (the 2nd-highest).
    static func nearestRank(_ percentile: Double, of sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((percentile * Double(sorted.count)).rounded(.up))
        return sorted[max(rank, 1) - 1]
    }
}

/// Starting thresholds for Bad (PRD §6.3), to be tuned in M7.
public struct Thresholds: Equatable, Sendable {
    /// Bad at this many lost probes in the window or more.
    public var lost: Int
    /// Bad above this jitter, in ms.
    public var jitter: Double
    /// Bad above this p95 RTT, in ms.
    public var p95: Double

    public init(lost: Int, jitter: Double, p95: Double) {
        self.lost = lost
        self.jitter = jitter
        self.p95 = p95
    }

    public static let router = Thresholds(lost: 2, jitter: 10, p95: 30)
    /// Internet hosts and custom targets.
    public static let internet = Thresholds(lost: 2, jitter: 30, p95: 150)
}

/// Which thresholds a Bad target crossed.
public struct Problems: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let loss = Problems(rawValue: 1 << 0)
    public static let jitter = Problems(rawValue: 1 << 1)
    public static let latency = Problems(rawValue: 1 << 2)
}

public enum TargetState: Equatable, Sendable {
    /// Warming up, or no probe has finished since the statistics started over.
    case measuring
    case ok
    case bad(Problems)
    /// An outage is in progress.
    case down

    var isBadOrDown: Bool {
        switch self {
        case .bad, .down: true
        case .measuring, .ok: false
        }
    }

    static func evaluate(_ metrics: Metrics, thresholds: Thresholds, isDown: Bool) -> TargetState {
        if isDown { return .down }
        guard metrics.sent > 0 else { return .measuring }
        var problems: Problems = []
        if metrics.lost >= thresholds.lost { problems.insert(.loss) }
        if let jitter = metrics.jitter, jitter > thresholds.jitter { problems.insert(.jitter) }
        if let p95 = metrics.p95, p95 > thresholds.p95 { problems.insert(.latency) }
        return problems.isEmpty ? .ok : .bad(problems)
    }
}

/// An outage or spike, logged once it has ended (PRD §6.3 Events).
public struct NetworkEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case outage, spike
    }

    public var kind: Kind
    public var role: TargetRole
    public var host: String
    public var address: ProbeAddress
    public var start: Date
    public var end: Date
    /// The highest RTT during a spike, in ms. nil for outages.
    public var worstRTT: Double?

    public init(kind: Kind, role: TargetRole, host: String, address: ProbeAddress, start: Date, end: Date, worstRTT: Double? = nil) {
        self.kind = kind
        self.role = role
        self.host = host
        self.address = address
        self.start = start
        self.end = end
        self.worstRTT = worstRTT
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// No reply for at least 5 s, with at least 3 probes in a row lost. Times are
/// send times, so the outage starts when the first lost probe was sent and ends
/// when the first probe that got a reply was sent.
struct OutageDetector {
    static let minimumDuration = 5.0
    static let minimumLost = 3

    private(set) var firstLost: Double?
    private(set) var lostInRow = 0
    /// The start of the outage in progress.
    private(set) var since: Double?

    /// Returns the start and end of an outage this reply ends.
    mutating func record(replied: Bool, at time: Double) -> (start: Double, end: Double)? {
        guard replied else {
            if firstLost == nil { firstLost = time }
            lostInRow += 1
            return nil
        }
        defer { self = OutageDetector() }
        return since.map { ($0, time) }
    }

    /// Starts an outage once both conditions hold. Run on every tick.
    mutating func check(now: Double) {
        guard since == nil, let firstLost, lostInRow >= Self.minimumLost, now - firstLost >= Self.minimumDuration else { return }
        since = firstLost
    }
}

/// RTT above both 3 × the window median and the median + 20 ms, for 3 or more
/// replies in a row. The median leaves out the spike's own replies, and needs
/// 5 replies outside it. Lost probes neither extend nor end a spike.
struct SpikeDetector {
    static let factor = 3.0
    static let margin = 20.0
    static let minimumReplies = 3
    static let minimumBaseline = 5

    private(set) var run: [(time: Double, rtt: Double)] = []

    /// - Parameter window: the window's replies before this one, oldest first.
    /// - Returns: a spike this reply ends, with its start, end and worst RTT.
    mutating func record(rtt: Double, at time: Double, window: [Double]) -> (start: Double, end: Double, worst: Double)? {
        let outside = window.dropLast(run.count).sorted()
        guard outside.count >= Self.minimumBaseline, let median = TargetStats.nearestRank(0.5, of: outside) else {
            // The window is all spike now: that's the new normal, not a spike.
            return finish(at: time)
        }
        if rtt > max(Self.factor * median, median + Self.margin) {
            run.append((time, rtt))
            return nil
        }
        return finish(at: time)
    }

    private mutating func finish(at time: Double) -> (start: Double, end: Double, worst: Double)? {
        defer { run.removeAll() }
        guard run.count >= Self.minimumReplies, let first = run.first else { return nil }
        return (first.time, time, run.map(\.rtt).max() ?? first.rtt)
    }
}

/// The popover header and menu bar summary (PRD §6.3).
public enum Verdict: String, Equatable, Sendable {
    case measuring
    case good
    /// The router is fine; the trouble is at the ISP or beyond.
    case internetProblem
    /// The router is fine, but nothing gets past it.
    case internetDown
    /// Wi‑Fi or the router.
    case localProblem
    /// Can't reach the router.
    case localDown
    /// The router can't be measured, so local and internet can't be told apart.
    case connectionProblem
    case connectionDown
    /// No internet host counts: every one answered locally, or none resolved.
    case internetUnmeasured
    case offline

    /// - Parameters:
    ///   - router: nil when there's no router, or it doesn't answer ping or is unreachable over the VPN.
    ///   - internet: the combined internet state; nil when no internet host counts.
    public static func combine(hasPath: Bool, router: TargetState?, internet: TargetState?) -> Verdict {
        guard hasPath else { return .offline }
        guard let internet else { return .internetUnmeasured }
        switch (router, internet) {
        // Router-only trouble isn't a local problem: routers often deprioritize ping to themselves.
        case (_, .ok): return .good
        case (_, .measuring), (.measuring?, _): return .measuring
        case (nil, .bad): return .connectionProblem
        case (nil, .down): return .connectionDown
        case (.ok?, .bad): return .internetProblem
        case (.ok?, .down): return .internetDown
        case (.down?, .down): return .localDown
        case (.bad?, _), (.down?, .bad): return .localProblem
        }
    }

    /// The internet is OK if any host is OK, Down if every host is Down, and
    /// Bad otherwise. nil when no host counts.
    public static func internet(_ hosts: [TargetState]) -> TargetState? {
        guard !hosts.isEmpty else { return nil }
        if hosts.contains(.ok) { return .ok }
        if hosts.allSatisfy({ $0 == .down }) { return .down }
        if hosts.contains(.measuring) { return .measuring }
        let problems = hosts.reduce(into: Problems()) { if case .bad(let p) = $1 { $0.formUnion(p) } }
        return .bad(problems)
    }
}

/// A verdict has to hold for 10 s before it's shown, so it doesn't flap.
/// After a network change the first verdict shows at once, as does Offline;
/// a return to measuring mid-run (a host switching to TCP) keeps the old one.
struct VerdictFilter {
    static let hold = 10.0

    private(set) var shown = Verdict.measuring
    private var pending: (verdict: Verdict, since: Double)?

    mutating func reset() {
        shown = .measuring
        pending = nil
    }

    mutating func update(_ verdict: Verdict, now: Double) -> Verdict {
        if verdict == shown || verdict == .measuring {
            pending = nil
        } else if shown == .measuring || shown == .offline || verdict == .offline {
            shown = verdict
            pending = nil
        } else if let pending, pending.verdict == verdict {
            if now - pending.since >= Self.hold {
                shown = verdict
                self.pending = nil
            }
        } else {
            pending = (verdict, now)
        }
        return shown
    }
}
