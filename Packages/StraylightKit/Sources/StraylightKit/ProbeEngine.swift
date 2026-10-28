import Darwin
import Dispatch

/// The probe loop (PRD §7.3). Watches the network, plans targets, runs
/// warm-up and the TCP fallback, and reports what it measures. Stats and the
/// verdict build on its events.
///
/// On every network change, settings change or wake from sleep, probes in
/// flight are discarded (never counted as lost), targets are re-resolved and
/// warm-up starts again.
public final class ProbeEngine: @unchecked Sendable {
    public enum ProbeProtocol: String, Sendable, Equatable {
        case icmp, tcp
    }

    public enum Event: Sendable, Equatable {
        /// After each re-plan. Every target then starts warming up.
        case targets(NetworkPath, [Target])
        /// A target's statistics start over on every status change, so ICMP
        /// losses from the warm-up of a host that switches to TCP don't linger.
        case status(TargetRole, TargetStatus)
        /// A measurement in the target's current mode. Check probes (TCP during
        /// warm-up, the once-a-minute ICMP retry) aren't reported.
        case result(TargetRole, ProbeProtocol, ProbeResult)
        /// A quarter second after each round of probes, once most replies are in.
        /// Time-based checks and snapshots hang off it.
        case tick
    }

    /// How long after a round of probes `.tick` is sent.
    static let tickDelay = 0.25

    private struct ProbeKey: Hashable {
        let probeProtocol: ProbeProtocol
        let sequence: UInt16
    }

    private struct SentProbe {
        let role: TargetRole
        let isCheck: Bool
        let sentAt: Double
    }

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "as.banast.straylight.probe")
    private let resolveQueue = DispatchQueue(label: "as.banast.straylight.resolve", qos: .utility)
    private let onEvent: @Sendable (Event) -> Void
    private let started = MachClock.now()
    private var settings: TargetSettings
    private var interval: Double
    private var icmp: ICMPProber!
    private var tcp: TCPProber!
    private var pathMonitor: PathMonitor!
    private var path = NetworkPath()
    private var order: [TargetRole] = []
    private var trackers: [TargetRole: TargetTracker] = [:]
    private var lastCheck: [TargetRole: Double] = [:]
    private var routerAnswered = false
    private var sent: [ProbeKey: SentProbe] = [:]
    private var generation = 0
    private var timer: DispatchSourceTimer?
    private var timerInterval: Double?
    private var sleepTotal: UInt64 = 0

    public init(settings: TargetSettings = TargetSettings(), interval: Double = 1, onEvent: @escaping @Sendable (Event) -> Void) {
        self.settings = settings
        self.interval = interval
        self.onEvent = onEvent
        icmp = ICMPProber(queue: queue) { [unowned self] in handle($0, .icmp) }
        tcp = TCPProber(queue: queue) { [unowned self] in handle($0, .tcp) }
        pathMonitor = PathMonitor(queue: queue) { [unowned self] in
            path = $0
            replan()
        }
    }

    public func start() {
        queue.async { [self] in
            sleepTotal = MachClock.sleepSinceBoot()
            pathMonitor.start()
        }
    }

    public func stop() {
        queue.sync { [self] in
            pathMonitor.stop()
            setTimer(nil)
            generation += 1
            discardInFlight()
            icmp.invalidate()
        }
    }

    public func update(settings: TargetSettings) {
        queue.async { [self] in
            guard settings != self.settings else { return }
            self.settings = settings
            replan()
        }
    }

    /// Seconds between probes once warm-up is over.
    public func update(interval: Double) {
        queue.async { [self] in
            self.interval = interval
            guard !order.isEmpty else { return }
            setTimer(tickInterval)
        }
    }

    // MARK: - Planning

    private var now: Double {
        MachClock.milliseconds(from: started, to: MachClock.now()) / 1000
    }

    private func discardInFlight() {
        icmp.discardInFlight()
        tcp.discardInFlight()
        sent.removeAll()
    }

    private func replan() {
        generation += 1
        let generation = generation
        setTimer(nil)
        discardInFlight()
        trackers.removeAll()
        order.removeAll()

        let (path, settings) = (path, settings)
        resolveQueue.async { [self] in
            let targets = TargetPlan.targets(for: path, settings: settings)
            queue.async { [self] in
                guard generation == self.generation else { return }
                install(targets, on: path)
            }
        }
    }

    private func install(_ targets: [Target], on path: NetworkPath) {
        let now = now
        order = targets.map(\.role)
        trackers = Dictionary(uniqueKeysWithValues: targets.map { ($0.role, TargetTracker(target: $0, isVPN: path.isVPN, now: now)) })
        lastCheck.removeAll()
        routerAnswered = false
        onEvent(.targets(path, targets))
        for role in order { onEvent(.status(role, .warmingUp)) }
        guard !targets.isEmpty else { return }
        setTimer(1)
        tick()
    }

    // MARK: - Ticks

    /// 1 s during warm-up or while any target is in fast recheck.
    private var tickInterval: Double {
        trackers.values.contains(where: \.needsFastTicks) ? min(1, interval) : interval
    }

    private func setTimer(_ seconds: Double?) {
        guard seconds != timerInterval else { return }
        timer?.cancel()
        timer = nil
        timerInterval = seconds
        guard let seconds else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(Int(seconds * 100)))
        timer.setEventHandler { [unowned self] in tick() }
        self.timer = timer
        timer.activate()
    }

    private func tick() {
        let sleep = MachClock.sleepSinceBoot()
        if sleep > sleepTotal, sleep - sleepTotal > MachClock.ticks(seconds: 1) {
            sleepTotal = sleep
            replan()
            return
        }

        icmp.checkTimeouts()
        tcp.checkTimeouts()
        let now = now

        for role in order {
            guard var tracker = trackers[role] else { continue }
            if let status = tracker.finishWarmUpIfDue(now: now) {
                trackers[role] = tracker
                statusChanged(role, status, now: now)
            }
            let sends = tracker.sends(now: now, interval: interval, routerAnswered: routerAnswered, sinceLastCheck: now - (lastCheck[role] ?? now))
            if (sends.icmp && !sends.icmpIsCheck) || (sends.tcp && !sends.tcpIsCheck) {
                trackers[role]?.didSend(now: now)
            }
            if sends.icmp {
                send(.icmp, to: tracker.target, isCheck: sends.icmpIsCheck, now: now)
                if sends.icmpIsCheck { lastCheck[role] = now }
            }
            if sends.tcp {
                send(.tcp, to: tracker.target, isCheck: sends.tcpIsCheck, now: now)
            }
        }

        sent = sent.filter { now - $0.value.sentAt < 60 }
        setTimer(tickInterval)
        let generation = generation
        queue.asyncAfter(deadline: .now() + Self.tickDelay) { [self] in
            guard generation == self.generation else { return }
            onEvent(.tick)
        }
    }

    private func send(_ probeProtocol: ProbeProtocol, to target: Target, isCheck: Bool, now: Double) {
        do {
            let sequence = switch probeProtocol {
            case .icmp: try icmp.send(to: target.address)
            case .tcp: try tcp.probe(target.address)
            }
            sent[ProbeKey(probeProtocol: probeProtocol, sequence: sequence)] = SentProbe(role: target.role, isCheck: isCheck, sentAt: now)
        } catch {
            // A send the kernel refuses (no route, say) is a lost probe.
            let result = ProbeResult(address: target.address, sequence: 0, sentAt: MachClock.now(), outcome: .lost)
            record(result, probeProtocol, role: target.role, isCheck: isCheck)
        }
    }

    private func statusChanged(_ role: TargetRole, _ status: TargetStatus, now: Double) {
        if status == .tcp || status == .doesntAnswerPing || status == .unreachableVPN {
            lastCheck[role] = now
        }
        onEvent(.status(role, status))
    }

    // MARK: - Results

    private func handle(_ result: ProbeResult, _ probeProtocol: ProbeProtocol) {
        guard let probe = sent[ProbeKey(probeProtocol: probeProtocol, sequence: result.sequence)] else { return }
        record(result, probeProtocol, role: probe.role, isCheck: probe.isCheck)
    }

    private func record(_ result: ProbeResult, _ probeProtocol: ProbeProtocol, role: TargetRole, isCheck: Bool) {
        guard var tracker = trackers[role] else { return }
        // A probe sent before a mode change (an ICMP probe from warm-up landing
        // after the switch to TCP, say) is no longer a measurement.
        let isMeasurement = !isCheck && Self.measures(tracker.status, probeProtocol)
        let replied: Bool
        switch result.outcome {
        case .reply: replied = true
        case .lost: replied = false
        case .late:
            if isMeasurement { onEvent(.result(role, probeProtocol, result)) }
            return
        }

        if isMeasurement { tracker.recordMeasurement(replied: replied, interval: interval) }
        var status: TargetStatus?
        switch probeProtocol {
        case .icmp:
            if role == .router, replied { routerAnswered = true }
            status = tracker.recordICMP(replied: replied)
        case .tcp:
            tracker.recordTCP(replied: replied)
        }
        trackers[role] = tracker
        // The result goes out before a status change, which starts the target's statistics over.
        if isMeasurement { onEvent(.result(role, probeProtocol, result)) }
        if let status { statusChanged(role, status, now: now) }
    }

    private static func measures(_ status: TargetStatus, _ probeProtocol: ProbeProtocol) -> Bool {
        status.measuredProtocol == probeProtocol
    }
}
