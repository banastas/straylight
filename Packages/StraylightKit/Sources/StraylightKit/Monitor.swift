import Darwin
import Foundation

/// One target as the popover shows it.
public struct TargetSnapshot: Equatable, Sendable {
    public var target: Target
    public var status: TargetStatus
    public var state: TargetState
    public var metrics: Metrics
    /// An internet host whose median RTT is at or below the router's baseline:
    /// something on the local network answers for it. Left out of the verdict.
    public var answeredLocally: Bool
    /// The start of the outage in progress.
    public var outageSince: Date?
}

public struct MonitorSnapshot: Equatable, Sendable {
    public var path = NetworkPath()
    /// In plan order: router, internet hosts, the primary host over IPv6, custom targets.
    public var targets: [TargetSnapshot] = []
    /// After the 10 s hold.
    public var verdict = Verdict.measuring
    /// The IPv4 internet hosts combined; nil when none counts.
    public var internet: TargetState?
    /// The primary host over IPv6 is Bad or Down while the internet over IPv4 is OK.
    public var ipv6Problem = false

    public init() {}

    public subscript(role: TargetRole) -> TargetSnapshot? {
        targets.first { $0.target.role == role }
    }
}

/// Statistics, target states, the verdict and events from the probe engine's
/// results, without sockets or clocks so it can be tested. Times are seconds on
/// a monotonic clock that keeps running during sleep; `date` turns them into
/// dates for events.
struct MonitorCore {
    /// Replies needed, from the router and the host, before "answered locally" is decided.
    static let answeredLocallyReplies = 5

    struct Record {
        let target: Target
        var status = TargetStatus.warmingUp
        var stats = TargetStats()
        var outage = OutageDetector()
        var spike = SpikeDetector()
        /// Measurements during warm-up, held until it's clear the target stays on ICMP.
        var warmUpProbes: [ProbeRecord] = []

        var thresholds: Thresholds { target.role == .router ? .router : .internet }
    }

    let date: (Double) -> Date
    private(set) var path = NetworkPath()
    private(set) var records: [Record] = []
    private var installed = false
    private var filter = VerdictFilter()
    /// Measurements for history, taken with `takeProbes()`.
    private var probes: [ProbeRecord] = []

    init(date: @escaping (Double) -> Date) {
        self.date = date
    }

    /// After a network change. Outages in progress end at `now`.
    mutating func install(_ targets: [Target], on path: NetworkPath, now: Double) -> [NetworkEvent] {
        let events = records.indices.compactMap { endOutage(at: $0, now: now) }
        self.path = path
        records = targets.map { Record(target: $0) }
        installed = true
        filter.reset()
        return events
    }

    mutating func setStatus(_ status: TargetStatus, for role: TargetRole, now: Double) -> [NetworkEvent] {
        guard let index = index(of: role) else { return [] }
        let old = records[index].status
        records[index].status = status
        let sameProtocol = old.measuredProtocol != nil && old.measuredProtocol == status.measuredProtocol
        if old == .warmingUp, status != .warmingUp {
            // A host that ends up on TCP never logs its warm-up ICMP losses.
            if sameProtocol { probes += records[index].warmUpProbes }
            records[index].warmUpProbes.removeAll()
        }
        // The statistics start over unless the target is still measured the same way.
        guard !sameProtocol else { return [] }
        let event = endOutage(at: index, now: now)
        records[index].stats = TargetStats()
        records[index].outage = OutageDetector()
        records[index].spike = SpikeDetector()
        return event.map { [$0] } ?? []
    }

    /// - Parameter sentAt: when the probe was sent.
    mutating func record(_ outcome: ProbeResult.Outcome, for role: TargetRole, sentAt time: Double) -> [NetworkEvent] {
        guard let index = index(of: role) else { return [] }
        let target = records[index].target
        let probe = ProbeRecord(target: target, probeProtocol: records[index].status.measuredProtocol ?? .icmp, outcome: outcome, sentAt: date(time))
        if records[index].status == .warmingUp {
            records[index].warmUpProbes.append(probe)
        } else {
            probes.append(probe)
        }
        var events: [NetworkEvent] = []
        switch outcome {
        case .reply(let rtt):
            if let spike = records[index].spike.record(rtt: rtt, at: time, window: records[index].stats.replies) {
                events.append(event(.spike, target, start: spike.start, end: spike.end, worst: spike.worst))
            }
            records[index].stats.record(rtt: rtt, at: time)
            if let outage = records[index].outage.record(replied: true, at: time) {
                events.append(event(.outage, target, start: outage.start, end: outage.end))
            }
        case .lost:
            records[index].stats.record(rtt: nil, at: time)
            _ = records[index].outage.record(replied: false, at: time)
        case .late:
            records[index].stats.recordLate(at: time)
        }
        return events
    }

    /// Starts outages that have now lasted long enough, and returns the snapshot.
    mutating func tick(now: Double) -> MonitorSnapshot {
        for index in records.indices where records[index].status != .warmingUp {
            records[index].outage.check(now: now)
        }
        return snapshot(now: now)
    }

    mutating func snapshot(now: Double) -> MonitorSnapshot {
        var snapshot = MonitorSnapshot()
        snapshot.path = path
        let router = records.first { $0.target.role == .router }
        let routerReplies = router?.stats.replies.count ?? 0
        let routerBaseline = router?.stats.metrics.baseline

        snapshot.targets = records.map { record in
            let metrics = record.stats.metrics
            let state: TargetState = record.status == .warmingUp
                ? .measuring
                : .evaluate(metrics, thresholds: record.thresholds, isDown: record.outage.since != nil)
            var answeredLocally = false
            if record.target.role.isInternet, let routerBaseline, let median = metrics.median,
               routerReplies >= Self.answeredLocallyReplies, record.stats.replies.count >= Self.answeredLocallyReplies {
                answeredLocally = median <= routerBaseline
            }
            return TargetSnapshot(
                target: record.target, status: record.status, state: state, metrics: metrics,
                answeredLocally: answeredLocally, outageSince: record.outage.since.map(date)
            )
        }

        let routerState = snapshot[.router].flatMap { $0.status.measuredProtocol == nil ? nil : $0.state }
        let hosts = snapshot.targets.filter {
            if case .internet = $0.target.role { !$0.answeredLocally && $0.status.measuredProtocol != nil } else { false }
        }
        snapshot.internet = Verdict.internet(hosts.map(\.state))
        if let ipv6 = snapshot[.internetIPv6], !ipv6.answeredLocally, snapshot.internet == .ok {
            snapshot.ipv6Problem = ipv6.state.isBadOrDown
        }

        let verdict = installed ? Verdict.combine(hasPath: path.isSatisfied, router: routerState, internet: snapshot.internet) : .measuring
        snapshot.verdict = filter.update(verdict, now: now)
        return snapshot
    }

    /// Measurements since the last call, for history.
    mutating func takeProbes() -> [ProbeRecord] {
        defer { probes.removeAll() }
        return probes
    }

    private func index(of role: TargetRole) -> Int? {
        records.firstIndex { $0.target.role == role }
    }

    private mutating func endOutage(at index: Int, now: Double) -> NetworkEvent? {
        guard let since = records[index].outage.since else { return nil }
        records[index].outage = OutageDetector()
        return event(.outage, records[index].target, start: since, end: now)
    }

    private func event(_ kind: NetworkEvent.Kind, _ target: Target, start: Double, end: Double, worst: Double? = nil) -> NetworkEvent {
        NetworkEvent(kind: kind, role: target.role, host: target.host, address: target.address, start: date(start), end: date(end), worstRTT: worst)
    }
}

/// Runs the probe engine and turns what it measures into statistics, target
/// states, the verdict, and outage and spike events (PRD §6.3). Updates come
/// on the engine's queue: a snapshot after every round of probes and after a
/// network change, and each event as it ends.
public final class Monitor: @unchecked Sendable {
    public enum Update: Sendable, Equatable {
        case snapshot(MonitorSnapshot)
        case event(NetworkEvent)
        /// Every measurement, for history. Warm-up results come once warm-up
        /// ends, and only if the target stays on ICMP.
        case probe(ProbeRecord)
    }

    // `core` is touched only from engine callbacks, which all run on the engine's queue.
    private var core: MonitorCore
    private var engine: ProbeEngine!
    private let onUpdate: @Sendable (Update) -> Void

    public init(settings: TargetSettings = TargetSettings(), interval: Double = 1, onUpdate: @escaping @Sendable (Update) -> Void) {
        self.onUpdate = onUpdate
        core = MonitorCore { seconds in Date(timeIntervalSinceNow: seconds - Self.continuousSeconds()) }
        engine = ProbeEngine(settings: settings, interval: interval) { [unowned self] in handle($0) }
    }

    public func start() { engine.start() }
    public func stop() { engine.stop() }
    public func update(settings: TargetSettings) { engine.update(settings: settings) }
    public func update(interval: Double) { engine.update(interval: interval) }

    /// Seconds on `mach_continuous_time`, which keeps running during sleep.
    static func continuousSeconds() -> Double {
        MachClock.milliseconds(from: 0, to: mach_continuous_time()) / 1000
    }

    private func handle(_ event: ProbeEngine.Event) {
        let now = Self.continuousSeconds()
        switch event {
        case .targets(let path, let targets):
            publish(core.install(targets, on: path, now: now))
            onUpdate(.snapshot(core.snapshot(now: now)))
        case .status(let role, let status):
            publish(core.setStatus(status, for: role, now: now))
        case .result(let role, _, let result):
            // Results arrive within seconds of the send, and a sleep in between
            // discards them, so the age on either clock is the same.
            let sentAt = now - MachClock.milliseconds(from: result.sentAt, to: MachClock.now()) / 1000
            publish(core.record(result.outcome, for: role, sentAt: sentAt))
        case .tick:
            onUpdate(.snapshot(core.tick(now: now)))
        }
        for probe in core.takeProbes() { onUpdate(.probe(probe)) }
    }

    private func publish(_ events: [NetworkEvent]) {
        for event in events { onUpdate(.event(event)) }
    }
}
