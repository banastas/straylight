import Foundation
import Testing
@testable import StraylightKit

@Suite struct HistoryChartTests {
    /// On the hour.
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let primary = Target(role: .internet(0), host: "1.1.1.1", address: ProbeAddress("1.1.1.1")!)

    func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    func row(_ minute: Int, median: Double, p95: Double, sent: Int = 60, lost: Int = 0, role: TargetRole = .internet(0)) -> AggregateRow {
        AggregateRow(start: at(Double(minute * 60)), seconds: 60, role: role, host: "1.1.1.1", address: "1.1.1.1", probeProtocol: .icmp,
                     sent: sent, lost: lost, late: 0, median: median, p95: p95, jitter: 1)
    }

    func period(_ minute: Int, _ state: MinuteState, rssi: Int? = nil) -> PeriodRow {
        PeriodRow(start: at(Double(minute * 60)), seconds: 60, state: state, rssi: rssi)
    }

    @Test func hourBucketsEndWithTheMinuteInProgress() {
        // 30 s into minute 60: minutes 1...59 are written, 60 isn't.
        let buckets = HistoryChart.buckets(.hour, role: .internet(0), periods: [period(59, .measured, rssi: -60)],
                                           aggregates: [row(59, median: 10, p95: 14, lost: 3)], now: at(3630))
        #expect(buckets.count == 60)
        #expect(buckets.first?.start == at(60) && buckets.last?.start == at(3600))
        #expect(buckets.last?.state == nil, "not written yet")
        let minute59 = buckets[58]
        #expect(minute59 == ChartBucket(start: at(3540), state: .measured, median: 10, p95: 14, lossPercent: 5, rssi: -60))
        #expect(buckets[0].state == .notRunning && buckets[0].median == nil && buckets[0].lossPercent == nil)
    }

    @Test func tenMinuteBucketsCombineMinutes() {
        let periods = (0..<10).map { period($0, $0 < 3 ? .measured : .asleep, rssi: $0 < 3 ? -50 - $0 : nil) }
        let rows = [row(0, median: 10, p95: 20), row(1, median: 12, p95: 40, lost: 6), row(2, median: 30, p95: 90),
                    row(1, median: 1, p95: 1, role: .router)]
        let buckets = HistoryChart.buckets(.day, role: .internet(0), periods: periods, aggregates: rows, now: at(86_000))
        #expect(buckets.count == 144)
        let bucket = try! #require(buckets.first { $0.start == base })
        #expect(bucket.state == .measured, "measured if any of it was")
        #expect(bucket.median == 12 && bucket.p95 == 90)
        #expect(bucket.lossPercent == 100.0 * 6 / 180)
        #expect(bucket.rssi == -51)
    }

    @Test func unmeasuredBucketsTakeTheMostCommonState() {
        // Four minutes asleep, six with no row at all.
        let periods = (0..<4).map { period($0, .asleep) }
        let buckets = HistoryChart.buckets(.day, role: .internet(0), periods: periods, aggregates: [], now: at(86_000))
        #expect(buckets.first { $0.start == base }?.state == .notRunning)
        let mostlyPaused = (0..<7).map { period($0, .paused) }
        #expect(HistoryChart.buckets(.day, role: .internet(0), periods: mostlyPaused, aggregates: [], now: at(86_000))
            .first { $0.start == base }?.state == .paused)
    }

    @Test func weekBucketsTakeHourlyRows() {
        let hour = AggregateRow(start: base, seconds: 3600, role: .internet(0), host: "1.1.1.1", address: "1.1.1.1", probeProtocol: .icmp,
                                sent: 3600, lost: 36, late: 0, median: 8, p95: 15, jitter: 1)
        let buckets = HistoryChart.buckets(.week, role: .internet(0), periods: [PeriodRow(start: base, seconds: 3600, state: .measured)],
                                           aggregates: [hour], now: at(6 * 86_400))
        #expect(buckets.count == 168)
        #expect(buckets.first { $0.start == base } == ChartBucket(start: base, state: .measured, median: 8, p95: 15, lossPercent: 1))
    }

    @Test func historyChartReadsWhatWasRecorded() throws {
        var store = try HistoryStore(db: Database(path: nil))
        for second in 0..<120 {
            store.record(ProbeRecord(target: primary, probeProtocol: .icmp, outcome: second == 5 ? .lost : .reply(milliseconds: 10), sentAt: at(Double(second))))
        }
        try store.flush(through: at(120), now: at(130), force: true)
        let rows = try store.aggregates(from: base, to: at(120), role: .internet(0))
        #expect(rows.count == 2)
        #expect(try store.aggregates(from: base, to: at(120), role: .router).isEmpty)
        let buckets = HistoryChart.buckets(.hour, role: .internet(0), periods: try store.periods(from: base, to: at(130)), aggregates: rows, now: at(130))
        #expect(buckets.suffix(3).map(\.state) == [.measured, .measured, nil])
    }

    @Test func latestEventsAreNewestFirst() throws {
        var store = try HistoryStore(db: Database(path: nil))
        for index in 0..<5 {
            store.record(NetworkEvent(kind: .spike, role: .internet(0), host: "1.1.1.1", address: primary.address,
                                      start: at(Double(index * 10)), end: at(Double(index * 10 + 4)), worstRTT: 50))
        }
        try store.flush(through: at(60), now: at(60))
        #expect(try store.latestEvents(limit: 3).map(\.start) == [at(40), at(30), at(20)])
    }
}

@Suite struct ProblemSummaryTests {
    func host(_ name: String, _ state: TargetState, lost: Int = 0, sent: Int = 60, p95: Double = 10, jitter: Double = 1) -> TargetSnapshot {
        var metrics = Metrics()
        metrics.sent = sent
        metrics.lost = lost
        metrics.p95 = p95
        metrics.jitter = jitter
        return TargetSnapshot(target: Target(role: .internet(0), host: name, address: ProbeAddress("192.0.2.1")!),
                              status: .icmp, state: state, metrics: metrics, answeredLocally: false)
    }

    @Test func lossComesFirstWithTheWorstValue() {
        let summary = ProblemSummary.of([
            host("1.1.1.1", .bad([.loss, .jitter]), lost: 5, jitter: 40),
            host("8.8.8.8", .bad(.loss), lost: 3),
            host("9.9.9.9", .ok),
        ])
        #expect(summary == ProblemSummary(kind: .loss, value: 100.0 * 5 / 60, hosts: ["1.1.1.1", "8.8.8.8"]))
    }

    @Test func latencyBeforeJitter() {
        let summary = ProblemSummary.of([host("1.1.1.1", .bad(.jitter), jitter: 45), host("8.8.8.8", .bad(.latency), p95: 210)])
        #expect(summary == ProblemSummary(kind: .latency, value: 210, hosts: ["8.8.8.8"]))
    }

    @Test func nothingBad() {
        #expect(ProblemSummary.of([host("1.1.1.1", .ok), host("8.8.8.8", .down)]) == nil)
    }
}
