import Foundation
import Testing
@testable import StraylightKit

@Suite struct TargetStatsTests {
    func stats(_ rtts: [Double?], every interval: Double = 1) -> TargetStats {
        var stats = TargetStats()
        for (index, rtt) in rtts.enumerated() { stats.record(rtt: rtt, at: Double(index) * interval) }
        return stats
    }

    @Test func nearestRank() {
        let sixty = (1...60).map(Double.init)
        #expect(TargetStats.nearestRank(0.95, of: sixty) == 57)
        #expect(TargetStats.nearestRank(0.5, of: sixty) == 30)
        #expect(TargetStats.nearestRank(0.95, of: (1...20).map(Double.init)) == 19)
        #expect(TargetStats.nearestRank(0.95, of: [4]) == 4)
        #expect(TargetStats.nearestRank(0.5, of: []) == nil)
    }

    @Test func metrics() {
        let metrics = stats([10, 12, nil, 11, 15, 9]).metrics
        #expect(metrics.sent == 6 && metrics.lost == 1)
        #expect(abs(metrics.lossPercent - 100.0 / 6) < 0.001)
        #expect(metrics.median == 11)
        #expect(metrics.p95 == 15)
        #expect(metrics.baseline == 9)
        #expect(metrics.latest == 9)
        // Pairs 10→12, 11→15, 15→9; 12→11 is split by the loss.
        #expect(metrics.jitter == (2.0 + 4 + 6) / 3)
    }

    @Test func noRepliesMeansNoRTTs() {
        let metrics = stats([nil, nil]).metrics
        #expect(metrics.median == nil && metrics.jitter == nil && metrics.latest == nil)
        #expect(metrics.lossPercent == 100)
    }

    @Test func windowIsSixtySecondsAtOneSecond() {
        let metrics = stats(Array(repeating: 5, count: 100)).metrics
        #expect(metrics.sent == 60)
    }

    @Test func windowIsTwentyProbesAtFiveSeconds() {
        let metrics = stats(Array(repeating: 5, count: 50), every: 5).metrics
        #expect(metrics.sent == 20)
    }

    @Test func baselineOutlivesTheWindow() {
        var stats = stats([1] + Array(repeating: 5, count: 99))
        #expect(stats.metrics.baseline == 1)
        stats.record(rtt: 6, at: 100)
        #expect(stats.metrics.median == 5 && stats.metrics.baseline == 1)
    }

    @Test func lossesReportedLateStayInSendOrder() {
        var stats = TargetStats()
        stats.record(rtt: 10, at: 0)
        stats.record(rtt: 20, at: 2)
        stats.record(rtt: nil, at: 1)
        #expect(stats.samples.map(\.time) == [0, 1, 2])
        #expect(stats.metrics.jitter == nil)
        #expect(stats.metrics.latest == 20)
    }

    @Test func lateRepliesCountWithinTheWindow() {
        var stats = stats([nil, 5])
        stats.recordLate(at: 0)
        #expect(stats.metrics.late == 1 && stats.metrics.lost == 1)
        for second in 2..<70 { stats.record(rtt: 5, at: Double(second)) }
        #expect(stats.metrics.late == 0)
    }
}

@Suite struct TargetStateTests {
    func metrics(lost: Int = 0, jitter: Double? = 1, p95: Double? = 10) -> Metrics {
        var metrics = Metrics()
        metrics.sent = 60
        metrics.lost = lost
        metrics.jitter = jitter
        metrics.p95 = p95
        return metrics
    }

    @Test func thresholds() {
        #expect(TargetState.evaluate(metrics(), thresholds: .router, isDown: false) == .ok)
        #expect(TargetState.evaluate(metrics(lost: 1), thresholds: .router, isDown: false) == .ok)
        #expect(TargetState.evaluate(metrics(lost: 2), thresholds: .router, isDown: false) == .bad(.loss))
        #expect(TargetState.evaluate(metrics(jitter: 11), thresholds: .router, isDown: false) == .bad(.jitter))
        #expect(TargetState.evaluate(metrics(jitter: 11), thresholds: .internet, isDown: false) == .ok)
        #expect(TargetState.evaluate(metrics(p95: 31), thresholds: .router, isDown: false) == .bad(.latency))
        #expect(TargetState.evaluate(metrics(p95: 151), thresholds: .internet, isDown: false) == .bad(.latency))
        #expect(TargetState.evaluate(metrics(lost: 3, p95: 200), thresholds: .internet, isDown: false) == .bad([.loss, .latency]))
    }

    @Test func downAndMeasuring() {
        #expect(TargetState.evaluate(metrics(), thresholds: .router, isDown: true) == .down)
        #expect(TargetState.evaluate(Metrics(), thresholds: .router, isDown: false) == .measuring)
    }
}

@Suite struct OutageDetectorTests {
    @Test func needsFiveSecondsAndThreeLost() {
        var detector = OutageDetector()
        _ = detector.record(replied: false, at: 10)
        _ = detector.record(replied: false, at: 11)
        detector.check(now: 20)
        #expect(detector.since == nil, "two lost probes aren't an outage, however long ago")

        _ = detector.record(replied: false, at: 12)
        detector.check(now: 14.9)
        #expect(detector.since == nil, "three lost, but under 5 s")
        detector.check(now: 15)
        #expect(detector.since == 10)

        let outage = detector.record(replied: true, at: 30)
        #expect(outage?.start == 10 && outage?.end == 30)
        #expect(detector.since == nil && detector.lostInRow == 0)
    }

    @Test func aReplyBeforeTheOutageStartsLogsNothing() {
        var detector = OutageDetector()
        for second in 0..<4 { _ = detector.record(replied: false, at: Double(second)) }
        #expect(detector.record(replied: true, at: 4) == nil)
        detector.check(now: 10)
        #expect(detector.since == nil)
    }
}

@Suite struct SpikeDetectorTests {
    /// Feeds replies through the detector the way `MonitorCore` does.
    func run(_ rtts: [Double]) -> [(start: Double, end: Double, worst: Double)] {
        var stats = TargetStats()
        var detector = SpikeDetector()
        var spikes: [(start: Double, end: Double, worst: Double)] = []
        for (index, rtt) in rtts.enumerated() {
            if let spike = detector.record(rtt: rtt, at: Double(index), window: stats.replies) { spikes.append(spike) }
            stats.record(rtt: rtt, at: Double(index))
        }
        return spikes
    }

    @Test func threeHighRepliesAreASpike() {
        let spikes = run(Array(repeating: 10, count: 10) + [50, 80, 60] + [10])
        #expect(spikes.count == 1)
        #expect(spikes.first?.start == 10 && spikes.first?.end == 13 && spikes.first?.worst == 80)
    }

    @Test func twoHighRepliesAreNot() {
        #expect(run(Array(repeating: 10, count: 10) + [50, 80, 10]).isEmpty)
    }

    @Test func needsBothThreeTimesAndTwentyMilliseconds() {
        // 3 × 2 ms = 6 ms is crossed, but the median + 20 ms isn't.
        #expect(run(Array(repeating: 2, count: 10) + [15, 15, 15, 2]).isEmpty)
        // The median + 20 ms is crossed, but 3 × 40 ms isn't.
        #expect(run(Array(repeating: 40, count: 10) + [100, 100, 100, 40]).isEmpty)
    }

    @Test func theMedianLeavesOutTheSpike() {
        // With the spike's replies in the median, the 6th to 9th high replies wouldn't count.
        let spikes = run(Array(repeating: 10, count: 6) + Array(repeating: 100, count: 9) + [10])
        #expect(spikes.count == 1)
        #expect(spikes.first?.start == 6 && spikes.first?.end == 15)
    }

    @Test func aLastingRiseIsTheNewNormal() {
        // Once the window holds fewer than 5 replies outside the run, it ends.
        let spikes = run(Array(repeating: 10, count: 5) + Array(repeating: 100, count: 70))
        #expect(spikes.count == 1)
        #expect(spikes.first?.start == 5)
    }

    @Test func needsFiveRepliesFirst() {
        #expect(run([10, 10, 10, 10, 100, 100, 100, 10]).isEmpty)
    }
}

@Suite struct VerdictTests {
    /// PRD §6.3, row by row.
    @Test(arguments: [
        (TargetState?.some(.ok), TargetState.ok, Verdict.good),
        (.bad(.loss), .ok, .good),
        (.down, .ok, .good),
        (.ok, .bad(.latency), .internetProblem),
        (.ok, .down, .internetDown),
        (.bad(.jitter), .bad(.loss), .localProblem),
        (.bad(.jitter), .down, .localProblem),
        (.down, .bad(.loss), .localProblem),
        (.down, .down, .localDown),
        (nil, .ok, .good),
        (nil, .bad(.loss), .connectionProblem),
        (nil, .down, .connectionDown),
        (.measuring, .bad(.loss), .measuring),
        (.ok, .measuring, .measuring),
        (.measuring, .ok, .good),
    ])
    func table(router: TargetState?, internet: TargetState, verdict: Verdict) {
        #expect(Verdict.combine(hasPath: true, router: router, internet: internet) == verdict)
    }

    @Test func offlineAndUnmeasured() {
        #expect(Verdict.combine(hasPath: false, router: .ok, internet: .ok) == .offline)
        #expect(Verdict.combine(hasPath: true, router: .ok, internet: nil) == .internetUnmeasured)
    }

    @Test func twoHosts() {
        #expect(Verdict.internet([.ok, .down]) == .ok)
        #expect(Verdict.internet([.bad(.loss), .ok]) == .ok)
        #expect(Verdict.internet([.down, .down]) == .down)
        #expect(Verdict.internet([.down, .bad(.latency)]) == .bad(.latency))
        #expect(Verdict.internet([.bad(.loss), .bad(.jitter)]) == .bad([.loss, .jitter]))
        #expect(Verdict.internet([.measuring, .down]) == .measuring)
        #expect(Verdict.internet([.down]) == .down)
        #expect(Verdict.internet([]) == nil)
    }
}

@Suite struct VerdictFilterTests {
    @Test func holdsTenSeconds() {
        var filter = VerdictFilter()
        #expect(filter.update(.good, now: 0) == .good, "the first verdict shows at once")
        #expect(filter.update(.internetProblem, now: 1) == .good)
        #expect(filter.update(.internetProblem, now: 10.9) == .good)
        #expect(filter.update(.internetProblem, now: 11) == .internetProblem)
    }

    @Test func aBriefChangeIsIgnored() {
        var filter = VerdictFilter()
        _ = filter.update(.good, now: 0)
        _ = filter.update(.internetDown, now: 1)
        #expect(filter.update(.good, now: 5) == .good)
        #expect(filter.update(.internetDown, now: 6) == .good)
        #expect(filter.update(.internetDown, now: 15) == .good, "the hold restarts after the break")
        #expect(filter.update(.internetDown, now: 16) == .internetDown)
    }

    @Test func offlineIsImmediateAndMeasuringKeepsTheVerdict() {
        var filter = VerdictFilter()
        _ = filter.update(.good, now: 0)
        #expect(filter.update(.measuring, now: 1) == .good)
        #expect(filter.update(.offline, now: 2) == .offline)
        #expect(filter.update(.good, now: 3) == .good)
        filter.reset()
        #expect(filter.shown == .measuring)
    }
}

@Suite struct MonitorCoreTests {
    let router = Target(role: .router, host: "router", address: ProbeAddress("192.168.1.1")!)
    let primary = Target(role: .internet(0), host: "1.1.1.1", address: ProbeAddress("1.1.1.1")!)
    let secondary = Target(role: .internet(1), host: "8.8.8.8", address: ProbeAddress("8.8.8.8")!)
    let ipv6 = Target(role: .internetIPv6, host: "1.1.1.1", address: ProbeAddress("2606:4700:4700::1111")!)

    var path: NetworkPath {
        var path = NetworkPath()
        path.isSatisfied = true
        path.hasIPv4 = true
        return path
    }

    func core(_ targets: [Target]) -> MonitorCore {
        var core = MonitorCore { Date(timeIntervalSinceReferenceDate: $0) }
        _ = core.install(targets, on: path, now: 0)
        return core
    }

    /// One probe a second to each target from `start`, `rtt` giving each outcome.
    func feed(_ core: inout MonitorCore, _ seconds: Range<Int>, _ rtt: (TargetRole, Int) -> Double?) -> [NetworkEvent] {
        var events: [NetworkEvent] = []
        for second in seconds {
            for record in core.records {
                let outcome: ProbeResult.Outcome = rtt(record.target.role, second).map { .reply(milliseconds: $0) } ?? .lost
                events += core.record(outcome, for: record.target.role, sentAt: Double(second))
            }
            _ = core.tick(now: Double(second) + 0.25)
        }
        return events
    }

    func normal(_ role: TargetRole, _ second: Int) -> Double? {
        role == .router ? 1 : 10
    }

    @Test func measuringUntilWarmUpEnds() {
        var core = core([router, primary])
        _ = feed(&core, 0..<10, normal)
        #expect(core.snapshot(now: 10).verdict == .measuring)
        for role in [TargetRole.router, .internet(0)] { _ = core.setStatus(.icmp, for: role, now: 10) }
        let snapshot = core.snapshot(now: 10)
        #expect(snapshot.verdict == .good)
        #expect(snapshot[.internet(0)]?.metrics.sent == 10, "warm-up samples count once the host stays on ICMP")
    }

    @Test func internetOutageAfterTheHold() {
        var core = core([router, primary, secondary])
        _ = feed(&core, 0..<10, normal)
        for role in [TargetRole.router, .internet(0), .internet(1)] { _ = core.setStatus(.icmp, for: role, now: 10) }
        _ = feed(&core, 10..<30, normal)
        #expect(core.snapshot(now: 30).verdict == .good)

        // Both hosts go silent at 30 s; the router keeps answering.
        _ = feed(&core, 30..<35) { role, _ in role == .router ? 1 : nil }
        let early = core.tick(now: 35)
        #expect(early[.internet(0)]?.outageSince == Date(timeIntervalSinceReferenceDate: 30))
        #expect(early.internet == .down)
        #expect(early.verdict == .good, "the verdict holds 10 s")
        _ = feed(&core, 35..<46) { role, _ in role == .router ? 1 : nil }
        #expect(core.tick(now: 46).verdict == .internetDown)

        let events = feed(&core, 46..<47, normal)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == .outage && $0.duration == 16 })
    }

    @Test func oneSlowHostIsntAnInternetProblem() {
        var core = core([router, primary, secondary])
        for role in [TargetRole.router, .internet(0), .internet(1)] { _ = core.setStatus(.icmp, for: role, now: 0) }
        _ = feed(&core, 0..<30) { role, _ in role == .router ? 1 : role == .internet(0) ? 200 : 5 }
        let snapshot = core.snapshot(now: 30)
        #expect(snapshot[.internet(0)]?.state == .bad(.latency))
        #expect(snapshot.internet == .ok && snapshot.verdict == .good)
    }

    @Test func warmUpLossesOfATCPHostAreNoOutage() {
        var core = core([router, primary])
        let events = feed(&core, 0..<10) { role, _ in role == .router ? 1 : nil }
        #expect(events.isEmpty)
        #expect(core.setStatus(.tcp, for: .internet(0), now: 10).isEmpty)
        _ = core.setStatus(.icmp, for: .router, now: 10)
        let snapshot = core.tick(now: 10.25)
        #expect(snapshot[.internet(0)]?.metrics.sent == 0, "the ICMP losses are gone")
        #expect(snapshot[.internet(0)]?.outageSince == nil)
        #expect(snapshot[.internet(0)]?.state == .measuring)
    }

    @Test func answeredLocallyIsLeftOut() {
        var core = core([router, primary, secondary])
        for role in [TargetRole.router, .internet(0), .internet(1)] { _ = core.setStatus(.icmp, for: role, now: 0) }
        // 1.1.1.1 answers faster than the router: something local intercepts it.
        _ = feed(&core, 0..<20) { role, _ in
            switch role {
            case .router: 2
            case .internet(0): 1.5
            default: nil
            }
        }
        let snapshot = core.snapshot(now: 20)
        #expect(snapshot[.internet(0)]?.answeredLocally == true)
        #expect(snapshot[.internet(1)]?.answeredLocally == false)
        #expect(snapshot.internet == .down, "only 8.8.8.8 counts, and it's down")
    }

    @Test func everyHostAnsweredLocallyCantBeMeasured() {
        var core = core([router, primary])
        for role in [TargetRole.router, .internet(0)] { _ = core.setStatus(.icmp, for: role, now: 0) }
        _ = feed(&core, 0..<20) { role, _ in role == .router ? 2 : 2 }
        #expect(core.snapshot(now: 20).verdict == .internetUnmeasured)
    }

    @Test func silentRouterGivesConnectionVerdicts() {
        var core = core([router, primary])
        _ = core.setStatus(.doesntAnswerPing, for: .router, now: 10)
        _ = core.setStatus(.icmp, for: .internet(0), now: 10)
        _ = feed(&core, 10..<20) { role, _ in role == .router ? nil : 400 }
        #expect(core.snapshot(now: 20).verdict == .connectionProblem)
    }

    @Test func ipv6ProblemIsNotedButDoesntDriveTheVerdict() {
        var core = core([router, primary, ipv6])
        for role in [TargetRole.router, .internet(0), .internetIPv6] { _ = core.setStatus(.icmp, for: role, now: 0) }
        _ = feed(&core, 0..<20) { role, second in role == .router ? 1 : role == .internetIPv6 && second % 2 == 0 ? nil : 10 }
        let snapshot = core.snapshot(now: 20)
        #expect(snapshot.verdict == .good)
        #expect(snapshot.ipv6Problem)
    }

    @Test func networkChangeEndsAnOutageInProgress() {
        var core = core([router, primary])
        for role in [TargetRole.router, .internet(0)] { _ = core.setStatus(.icmp, for: role, now: 0) }
        _ = feed(&core, 0..<10) { role, _ in role == .router ? 1 : nil }
        let events = core.install([router, primary], on: path, now: 12)
        #expect(events.map(\.kind) == [.outage])
        #expect(events.first?.duration == 12)
        #expect(core.snapshot(now: 12).verdict == .measuring)
    }

    @Test func spikesAreLogged() {
        var core = core([router, primary])
        for role in [TargetRole.router, .internet(0)] { _ = core.setStatus(.icmp, for: role, now: 0) }
        let events = feed(&core, 0..<20) { role, second in role == .internet(0) && (10..<14).contains(second) ? 90 : 10 }
        #expect(events.map(\.kind) == [.spike])
        #expect(events.first?.worstRTT == 90 && events.first?.duration == 4)
    }

    @Test func offlineWithoutAPath() {
        var core = MonitorCore { Date(timeIntervalSinceReferenceDate: $0) }
        _ = core.install([], on: NetworkPath(), now: 0)
        #expect(core.snapshot(now: 0).verdict == .offline)
    }
}

@Suite struct FastRecheckTests {
    let internet = Target(role: .internet(0), host: "1.1.1.1", address: ProbeAddress("1.1.1.1")!)

    func tracker() -> TargetTracker {
        var tracker = TargetTracker(target: internet, isVPN: false, now: 0)
        _ = tracker.recordICMP(replied: true)
        _ = tracker.finishWarmUpIfDue(now: 10)
        return tracker
    }

    @Test func probesAtTheIntervalOnOneSecondTicks() {
        var tracker = tracker()
        tracker.didSend(now: 10)
        let due = (11...20).filter { tracker.sends(now: Double($0), interval: 5, routerAnswered: true, sinceLastCheck: 0).icmp }
        #expect(due.first == 15)
        // Timer leeway can bring the 5th tick in early.
        #expect(tracker.sends(now: 14.6, interval: 5, routerAnswered: true, sinceLastCheck: 0).icmp)
    }

    @Test func aLossProbesEverySecondUntilThreeReplies() {
        var tracker = tracker()
        tracker.didSend(now: 10)
        tracker.recordMeasurement(replied: false, interval: 5)
        #expect(tracker.isRechecking && tracker.needsFastTicks)
        #expect(tracker.sends(now: 11, interval: 5, routerAnswered: true, sinceLastCheck: 0).icmp)

        tracker.recordMeasurement(replied: true, interval: 5)
        tracker.recordMeasurement(replied: true, interval: 5)
        tracker.recordMeasurement(replied: false, interval: 5)
        tracker.recordMeasurement(replied: true, interval: 5)
        tracker.recordMeasurement(replied: true, interval: 5)
        #expect(tracker.isRechecking, "the loss restarted the count")
        tracker.recordMeasurement(replied: true, interval: 5)
        #expect(!tracker.isRechecking && !tracker.needsFastTicks)
    }

    @Test func recheckCarriesOnPastWarmUp() {
        var tracker = TargetTracker(target: internet, isVPN: false, now: 0)
        _ = tracker.recordICMP(replied: true)
        tracker.recordMeasurement(replied: false, interval: 5)
        _ = tracker.finishWarmUpIfDue(now: 10)
        #expect(tracker.status == .icmp && tracker.isRechecking)
    }

    @Test func noRecheckAtOneSecond() {
        var tracker = tracker()
        tracker.recordMeasurement(replied: false, interval: 1)
        #expect(!tracker.isRechecking)
    }
}

@Suite struct MenuBarTextTests {
    @Test(arguments: [
        (Double?.none, "—"), (0.42, "0.4ms"), (5.44, "5.4ms"), (9.96, "10ms"), (23.4, "23ms"),
        (999.4, "999ms"), (999.6, "1.0s"), (1234, "1.2s"), (12_000, "12s"), (-1, "—"),
    ])
    func rtt(milliseconds: Double?, text: String) {
        #expect(MenuBarText.rtt(milliseconds) == text)
        #expect(text.count <= MenuBarText.widestRTT.count)
    }

    @Test func marks() {
        #expect(MenuBarText.mark(for: .good, paused: false) == "")
        #expect(MenuBarText.mark(for: .measuring, paused: false) == "")
        #expect(MenuBarText.mark(for: .internetProblem, paused: false) == "!")
        #expect(MenuBarText.mark(for: .localDown, paused: false) == "×")
        #expect(MenuBarText.mark(for: .offline, paused: false) == "×")
        #expect(MenuBarText.mark(for: .offline, paused: true) == "‖")
    }

    @Test func trace() {
        #expect(MenuBarText.trace([10, nil, 20], floor: 5) == [0.5, 0, 1])
        #expect(MenuBarText.trace([1, 2], floor: 8) == [0.125, 0.25])
        #expect(MenuBarText.trace([nil, nil], floor: 8) == [0, 0])
    }
}
