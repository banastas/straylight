import Foundation
import Testing
@testable import StraylightKit

@Suite struct HistoryStoreTests {
    /// On the hour, so minute and hour boundaries are easy to read.
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let router = Target(role: .router, host: "router", address: ProbeAddress("192.168.1.1")!)
    let primary = Target(role: .internet(0), host: "1.1.1.1", address: ProbeAddress("1.1.1.1")!)

    func store() throws -> HistoryStore {
        var store = try HistoryStore(db: Database(path: nil))
        store.timeZone = TimeZone(secondsFromGMT: -7 * 3600)!
        return store
    }

    func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    func probe(_ target: Target, _ outcome: ProbeResult.Outcome, at seconds: Double, _ probeProtocol: ProbeEngine.ProbeProtocol = .icmp) -> ProbeRecord {
        ProbeRecord(target: target, probeProtocol: probeProtocol, outcome: outcome, sentAt: at(seconds))
    }

    /// One probe a second to `target` over `seconds`.
    func feed(_ store: inout HistoryStore, _ target: Target, _ seconds: Range<Int>, _ rtt: (Int) -> Double?) {
        for second in seconds {
            store.record(probe(target, rtt(second).map { .reply(milliseconds: $0) } ?? .lost, at: Double(second)))
        }
    }

    @Test func aggregatesAMinute() throws {
        var store = try store()
        feed(&store, primary, 0..<60) { $0 == 10 ? nil : Double($0 % 3) + 10 }
        store.record(probe(primary, .late(milliseconds: 2500), at: 10))
        try store.flush(through: at(60), now: at(100))

        let rows = try store.aggregates(from: base, to: at(60))
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.seconds == 60 && row.host == "1.1.1.1" && row.address == "1.1.1.1" && row.probeProtocol == .icmp)
        #expect(row.sent == 60 && row.lost == 1 && row.late == 1)
        #expect(row.median == 11 && row.p95 == 12)
        #expect(try store.periods(from: base, to: at(60)) == [PeriodRow(start: base, seconds: 60, state: .measured, rssi: nil)])
    }

    @Test func writesOnlyFinishedMinutesAndAtMostOnceAMinute() throws {
        var store = try store()
        feed(&store, primary, 0..<90) { _ in 10 }
        try store.flush(through: at(90), now: at(130))
        #expect(try store.periods(from: base, to: at(3600)).count == 1, "the minute in progress waits")
        #expect(store.open.count == 1)

        feed(&store, primary, 90..<150) { _ in 10 }
        try store.flush(through: at(150), now: at(150))
        #expect(try store.periods(from: base, to: at(3600)).count == 1, "under a minute since the last write")
        try store.flush(through: at(150), now: at(190))
        #expect(try store.periods(from: base, to: at(3600)).count == 2)
    }

    @Test func minuteStates() throws {
        var store = try store()
        feed(&store, primary, 0..<30) { _ in 10 }
        store.setState(.paused, now: at(30))
        store.touch(now: at(70), rssi: -60)
        store.touch(now: at(80), rssi: -64)
        store.touch(now: at(100), rssi: -62)
        store.setState(.offline, now: at(130))
        // Asleep from 3:10 to 10:00; 3:00 had nothing measured, so it's asleep too.
        store.touch(now: at(185), rssi: nil)
        store.markAsleep(from: at(190), to: at(600))
        store.setState(.measured, now: at(600))
        try store.flush(through: at(600), now: at(700))

        let periods = try store.periods(from: base, to: at(600))
        #expect(periods.map(\.state) == [.measured, .paused, .offline, .asleep, .asleep, .asleep, .asleep, .asleep, .asleep, .asleep])
        #expect(periods[1].rssi == -62)
    }

    @Test func sleepAfterMeasuringKeepsTheMinuteMeasured() throws {
        var store = try store()
        feed(&store, primary, 0..<20) { _ in 10 }
        store.markAsleep(from: at(20), to: at(200))
        try store.flush(through: at(200), now: at(300))
        #expect(try store.periods(from: base, to: at(200)).map(\.state) == [.measured, .asleep, .asleep])
    }

    @Test func aMinuteWrittenTwiceAddsUp() throws {
        var store = try store()
        feed(&store, primary, 0..<20) { _ in 10 }
        try store.flush(through: .distantFuture, now: at(20), force: true)
        // The app restarts in the same minute.
        var again = store
        feed(&again, primary, 30..<60) { $0 == 40 ? nil : 20 }
        try again.flush(through: .distantFuture, now: at(60), force: true)

        let row = try #require(try again.aggregates(from: base, to: at(60)).first)
        #expect(row.sent == 50 && row.lost == 1)
        #expect(row.median == 20, "from the part with more replies")
    }

    @Test func rollsUpToHoursAfterSevenDays() throws {
        var store = try store()
        store.setState(.measured, now: base)
        // 0:00 to 0:30 at 10 ms, 0:30 to 1:00 at 30 ms.
        feed(&store, primary, 0..<3600) { $0 < 1800 ? 10 : 30 }
        feed(&store, router, 0..<600) { _ in 1 }
        try store.flush(through: at(3600), now: at(3700))
        #expect(try store.aggregates(from: base, to: at(3600)).count == 70)

        var later = store
        later.touch(now: at(8 * 86_400), rssi: nil)
        try later.flush(through: at(8 * 86_400), now: at(8 * 86_400 + 3600))
        let rows = try later.aggregates(from: base, to: at(3600))
        #expect(rows.map(\.role) == [.router, .internet(0)])
        let hour = try #require(rows.last)
        #expect(hour.seconds == 3600 && hour.sent == 3600 && hour.median == 10 && hour.p95 == 30)
        #expect(try later.periods(from: base, to: at(3600)) == [PeriodRow(start: base, seconds: 3600, state: .measured, rssi: nil)])
    }

    @Test func retentionPrunesOldRowsAndEvents() throws {
        var store = try store()
        store.retentionDays = 7
        feed(&store, primary, 0..<60) { _ in 10 }
        store.record(NetworkEvent(kind: .outage, role: .internet(0), host: "1.1.1.1", address: primary.address, start: at(10), end: at(20)))
        try store.flush(through: at(60), now: at(100))
        #expect(try store.events(from: base, to: at(60)).count == 1)

        store.touch(now: at(8 * 86_400), rssi: nil)
        try store.flush(through: at(8 * 86_400), now: at(8 * 86_400 + 3600))
        #expect(try store.periods(from: base, to: at(3600)).isEmpty)
        #expect(try store.aggregates(from: base, to: at(3600)).isEmpty)
        #expect(try store.events(from: base, to: at(60)).isEmpty)
    }

    @Test func aggregatesCSV() throws {
        var store = try store()
        feed(&store, router, 0..<60) { _ in 1 }
        feed(&store, primary, 0..<60) { $0 < 3 ? nil : 10 }
        store.touch(now: at(30), rssi: -58)
        store.markAsleep(from: at(120), to: at(180))
        try store.flush(through: at(180), now: at(200))

        let csv = try store.aggregatesCSV(from: base, to: at(240), now: at(240))
        #expect(csv == """
            start,period_s,state,target,address,protocol,sent,lost,late,loss_pct,median_ms,p95_ms,jitter_ms,rssi_dbm
            2027-01-15T01:00:00-07:00,60,measured,router,192.168.1.1,icmp,60,0,0,0.0,1.000,1.000,0.000,-58
            2027-01-15T01:00:00-07:00,60,measured,1.1.1.1,1.1.1.1,icmp,60,3,0,5.0,10.000,10.000,0.000,-58
            2027-01-15T01:01:00-07:00,60,not_running,,,,,,,,,,,
            2027-01-15T01:02:00-07:00,60,asleep,,,,,,,,,,,
            2027-01-15T01:03:00-07:00,60,not_running,,,,,,,,,,,

            """)
        #expect(Set(csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).count }) == [14])
    }

    @Test func oldGapsExportByTheHour() throws {
        let store = try store()
        let csv = try store.aggregatesCSV(from: base, to: at(7200), now: at(30 * 86_400))
        #expect(csv.split(separator: "\n").dropFirst() == ["2027-01-15T01:00:00-07:00,3600,not_running,,,,,,,,,,,", "2027-01-15T02:00:00-07:00,3600,not_running,,,,,,,,,,,"])
    }

    @Test func eventsCSV() throws {
        var store = try store()
        store.record(NetworkEvent(kind: .outage, role: .internet(0), host: "1.1.1.1", address: primary.address, start: at(10), end: at(26.5)))
        store.record(NetworkEvent(kind: .spike, role: .router, host: "router", address: router.address, start: at(40), end: at(44), worstRTT: 87.25))
        try store.flush(through: at(60), now: at(60))
        #expect(try store.eventsCSV(from: base, to: at(60)) == """
            start,end,duration_s,type,target,address,worst_rtt_ms
            2027-01-15T01:00:10-07:00,2027-01-15T01:00:26-07:00,16.5,outage,1.1.1.1,1.1.1.1,
            2027-01-15T01:00:40-07:00,2027-01-15T01:00:44-07:00,4.0,spike,router,192.168.1.1,87.250

            """)
    }

    @Test func eventsRoundTrip() throws {
        var store = try store()
        let event = NetworkEvent(kind: .spike, role: .internetIPv6, host: "1.1.1.1", address: ProbeAddress("2606:4700:4700::1111")!, start: at(1), end: at(5), worstRTT: 40)
        store.record(event)
        try store.flush(through: at(60), now: at(60))
        #expect(try store.events(from: base, to: at(60)) == [event])
    }

    @Test(arguments: [TargetRole.router, .internet(0), .internet(1), .internetIPv6, .custom(1)])
    func rolesRoundTrip(role: TargetRole) {
        #expect(TargetRole(role.description) == role)
    }

    @Test func fileDatabaseReopens() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "straylight-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var store = try HistoryStore(db: Database(path: url.path))
        feed(&store, primary, 0..<60) { _ in 10 }
        try store.flush(through: at(60), now: at(100))
        let reopened = try HistoryStore(db: Database(path: url.path))
        #expect(try reopened.aggregates(from: base, to: at(60)).count == 1)
    }
}

@Suite struct MonitorHistoryTests {
    let router = Target(role: .router, host: "router", address: ProbeAddress("192.168.1.1")!)
    let host = Target(role: .internet(0), host: "amazon.com", address: ProbeAddress("205.251.242.103")!)

    func core() -> MonitorCore {
        var path = NetworkPath()
        path.isSatisfied = true
        path.hasIPv4 = true
        var core = MonitorCore { Date(timeIntervalSinceReferenceDate: $0) }
        _ = core.install([router, host], on: path, now: 0)
        return core
    }

    @Test func warmUpProbesWaitForTheEndOfWarmUp() {
        var core = core()
        for second in 0..<10 {
            _ = core.record(.reply(milliseconds: 1), for: .router, sentAt: Double(second))
            _ = core.record(.lost, for: .internet(0), sentAt: Double(second))
        }
        #expect(core.takeProbes().isEmpty)

        _ = core.setStatus(.icmp, for: .router, now: 10)
        _ = core.setStatus(.tcp, for: .internet(0), now: 10)
        let probes = core.takeProbes()
        #expect(probes.count == 10 && probes.allSatisfy { $0.target.role == .router })

        _ = core.record(.reply(milliseconds: 68), for: .internet(0), sentAt: 11)
        #expect(core.takeProbes().map(\.probeProtocol) == [.tcp])
    }
}

@Suite struct HistoryInboxTests {
    let target = Target(role: .router, host: "router", address: ProbeAddress("192.168.1.1")!)

    /// Rounds wait in the inbox; reads and state changes see them in call order.
    @Test func roundsAndStatesLandInOrder() throws {
        let history = try History(url: nil)
        let now = Date()
        history.record([ProbeRecord(target: target, probeProtocol: .icmp, outcome: .reply(milliseconds: 2), sentAt: now)], state: .measured)
        history.setState(.paused)
        history.record([], state: .measured)
        history.setState(.locked)

        // Writes everything, including the minute in progress.
        history.close()
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let periods = try history.periods(from: minute, to: minute.addingTimeInterval(60))
        #expect(periods.map(\.state) == [.measured], "a minute with a measurement is measured")
        let rows = try history.aggregates(from: minute, to: minute.addingTimeInterval(60))
        #expect(rows.map(\.sent) == [1])
    }

    @Test func aStateSetAfterARoundWins() throws {
        let history = try History(url: nil)
        let now = Date()
        history.record([], state: .measured)
        history.setState(.paused)
        history.close()
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        #expect(try history.periods(from: minute, to: minute.addingTimeInterval(60)).map(\.state) == [.paused])
    }
}
