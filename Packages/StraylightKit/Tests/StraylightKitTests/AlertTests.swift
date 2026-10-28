import Foundation
import Testing
@testable import StraylightKit

@Suite struct AlertTrackerTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    func host(_ index: Int, _ state: TargetState, outageSince: Date? = nil) -> TargetSnapshot {
        let name = index == 0 ? "1.1.1.1" : "8.8.8.8"
        return TargetSnapshot(target: Target(role: .internet(index), host: name, address: ProbeAddress(name)!), status: .icmp,
                              state: state, metrics: Metrics(), answeredLocally: false, outageSince: outageSince)
    }

    func snapshot(_ verdict: Verdict, internet: TargetState?, hosts: [TargetSnapshot] = []) -> MonitorSnapshot {
        var snapshot = MonitorSnapshot()
        snapshot.verdict = verdict
        snapshot.internet = internet
        snapshot.targets = hosts
        return snapshot
    }

    var good: MonitorSnapshot { snapshot(.good, internet: .ok, hosts: [host(0, .ok), host(1, .ok)]) }

    func down(since: Double, verdict: Verdict = .internetDown) -> MonitorSnapshot {
        snapshot(verdict, internet: .down, hosts: [host(0, .down, outageSince: at(since - 2)), host(1, .down, outageSince: at(since))])
    }

    @Test func outageIsPostedAfterTenSecondsAndAgainWhenItEnds() {
        var tracker = AlertTracker(outages: true)
        #expect(tracker.update(good, now: at(0)).isEmpty)
        #expect(tracker.update(down(since: 100), now: at(105)).isEmpty)
        #expect(tracker.update(down(since: 100), now: at(110)) == [.internetDown(since: at(100), hosts: ["1.1.1.1", "8.8.8.8"], verdict: .internetDown)])
        #expect(tracker.update(down(since: 100), now: at(120)).isEmpty, "posted once")
        #expect(tracker.update(good, now: at(163)) == [.internetBack(after: 63)])
        #expect(tracker.update(good, now: at(164)).isEmpty)
    }

    @Test func shortOutagesAndWarmUpAreQuiet() {
        var tracker = AlertTracker(outages: true)
        _ = tracker.update(down(since: 0), now: at(5))
        #expect(tracker.update(good, now: at(8)).isEmpty, "over before 10 s")

        _ = tracker.update(down(since: 20), now: at(31))
        // A network change mid-outage: warm-up doesn't end it.
        #expect(tracker.update(snapshot(.measuring, internet: .measuring), now: at(35)).isEmpty)
        #expect(tracker.update(good, now: at(45)) == [.internetBack(after: 25)])
    }

    @Test func outagesOffPostsNothing() {
        var tracker = AlertTracker()
        _ = tracker.update(down(since: 0), now: at(1))
        #expect(tracker.update(down(since: 0), now: at(60)).isEmpty)
        #expect(tracker.update(good, now: at(70)).isEmpty)
    }

    @Test func resetForgetsAnOutage() {
        var tracker = AlertTracker(outages: true)
        _ = tracker.update(down(since: 0), now: at(11))
        tracker.reset()
        #expect(tracker.update(good, now: at(20)).isEmpty, "no internet back after a pause")
    }

    @Test func verdictChangesThatHoldThirtySeconds() {
        var tracker = AlertTracker(verdictChanges: true)
        let problem = snapshot(.internetProblem, internet: .bad(.loss), hosts: [host(0, .bad(.loss)), host(1, .bad(.loss))])
        #expect(tracker.update(snapshot(.measuring, internet: .measuring), now: at(0)).isEmpty)
        _ = tracker.update(good, now: at(10))
        #expect(tracker.update(good, now: at(40)).isEmpty, "the first verdict is the starting point")
        _ = tracker.update(problem, now: at(50))
        #expect(tracker.update(good, now: at(60)).isEmpty, "back before 30 s")
        _ = tracker.update(problem, now: at(70))
        #expect(tracker.update(problem, now: at(99)).isEmpty)
        #expect(tracker.update(problem, now: at(100)) == [.verdict(.internetProblem)])
        #expect(tracker.update(problem, now: at(200)).isEmpty, "posted once")
        // Measuring in between (a network change) doesn't count as a change.
        _ = tracker.update(snapshot(.measuring, internet: .measuring), now: at(210))
        #expect(tracker.update(problem, now: at(260)).isEmpty)
    }

    @Test func anOutageAlertCoversTheDownVerdictAndTheReturnToGood() {
        var tracker = AlertTracker(outages: true, verdictChanges: true)
        _ = tracker.update(good, now: at(0))
        _ = tracker.update(good, now: at(30))
        var alerts: [AlertTracker.Alert] = []
        for second in stride(from: 100.0, through: 200, by: 1) {
            alerts += tracker.update(down(since: 100), now: at(second))
        }
        #expect(alerts == [.internetDown(since: at(100), hosts: ["1.1.1.1", "8.8.8.8"], verdict: .internetDown)])
        alerts = []
        for second in stride(from: 201.0, through: 300, by: 1) {
            alerts += tracker.update(good, now: at(second))
        }
        #expect(alerts == [.internetBack(after: 101)])
    }
}

@Suite struct ThresholdReportTests {
    func row(_ role: TargetRole, host: String, lost: Int = 0, p95: Double, jitter: Double, seconds: Int = 60) -> AggregateRow {
        AggregateRow(start: Date(timeIntervalSince1970: 0), seconds: seconds, role: role, host: host, address: host, probeProtocol: .icmp,
                     sent: 60, lost: lost, late: 0, median: p95 / 2, p95: p95, jitter: jitter)
    }

    @Test func countsMinutesOverEachThreshold() {
        var rows = (0..<98).map { _ in row(.router, host: "router", p95: 3, jitter: 1) }
        rows.append(row(.router, host: "router", lost: 2, p95: 3, jitter: 1))
        rows.append(row(.router, host: "router", p95: 40, jitter: 12))
        rows += (0..<10).map { row(.internet(0), host: "1.1.1.1", p95: Double(10 + $0), jitter: 2) }
        rows.append(row(.internetIPv6, host: "1.1.1.1", p95: 200, jitter: 2))
        rows.append(row(.router, host: "router", lost: 60, p95: 3, jitter: 1, seconds: 3600))

        let report = ThresholdReport(rows)
        #expect(report.lines.map(\.target) == ["router", "1.1.1.1", "1.1.1.1 (IPv6)"])
        let router = report.lines[0]
        #expect(router.minutes == 100, "hourly rows are left out")
        #expect(router.overLoss == 1 && router.overP95 == 1 && router.overJitter == 1 && router.bad == 2)
        #expect(router.p95 == [3, 3, 3], "p99 over 100 minutes is the 99th")
        #expect(report.lines[1].p95 == [14, 19, 19] && report.lines[1].bad == 0)
        #expect(report.lines[2].overP95 == 1)
        #expect(report.text.contains("router: 100 minutes, 2.0% Bad"))
    }
}
