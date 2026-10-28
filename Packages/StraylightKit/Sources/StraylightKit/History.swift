import Dispatch
import Foundation
import os

/// What straylight was doing during a minute (PRD §6.4). Minutes with no row
/// at all are `notRunning`: the app wasn't open.
public enum MinuteState: String, Sendable, CaseIterable {
    case measured, paused, locked, asleep, offline
    case notRunning = "not_running"
}

/// One measurement, as `Monitor` forwards it for history.
public struct ProbeRecord: Equatable, Sendable {
    public var target: Target
    public var probeProtocol: ProbeEngine.ProbeProtocol
    public var outcome: ProbeResult.Outcome
    public var sentAt: Date

    public init(target: Target, probeProtocol: ProbeEngine.ProbeProtocol, outcome: ProbeResult.Outcome, sentAt: Date) {
        self.target = target
        self.probeProtocol = probeProtocol
        self.outcome = outcome
        self.sentAt = sentAt
    }
}

/// A minute, or an hour once rolled up, and its state.
public struct PeriodRow: Equatable, Sendable {
    public var start: Date
    /// 60 or 3600.
    public var seconds: Int
    public var state: MinuteState
    /// Median Wi‑Fi RSSI over the period, in dBm; nil when not on Wi‑Fi.
    public var rssi: Int?
}

/// One target's numbers for a minute or an hour. RTTs are in ms.
public struct AggregateRow: Equatable, Sendable {
    public var start: Date
    public var seconds: Int
    public var role: TargetRole
    public var host: String
    public var address: String
    public var probeProtocol: ProbeEngine.ProbeProtocol
    public var sent: Int
    public var lost: Int
    public var late: Int
    public var median: Double?
    public var p95: Double?
    public var jitter: Double?

    public var lossPercent: Double {
        sent == 0 ? 0 : 100 * Double(lost) / Double(sent)
    }
}

/// The history database's logic, without queues or timers so it can be tested.
/// Minutes are collected in memory and written once they can no longer change:
/// 40 s after they end, long enough for a late reply (2 s timeout plus the 30 s
/// late window) to land in the minute it was sent in.
struct HistoryStore {
    static let schemaVersion = 1
    static let minuteDetailDays = 7
    static let grace: TimeInterval = 40
    static let writeInterval: TimeInterval = 60
    static let maintenanceInterval: TimeInterval = 3600

    struct Key: Hashable {
        let role: TargetRole
        let host: String
        let address: String
        let probeProtocol: ProbeEngine.ProbeProtocol
    }

    struct Accumulator {
        var samples: [TargetStats.Sample] = []
        var late = 0
    }

    struct OpenMinute {
        var state: MinuteState
        var rssi: [Int] = []
        var targets: [Key: Accumulator] = [:]
    }

    let db: Database
    var retentionDays = 30
    var timeZone = TimeZone.current
    private(set) var state = MinuteState.measured
    private(set) var open: [Int: OpenMinute] = [:]
    private var pendingEvents: [NetworkEvent] = []
    private var lastWrite: Date?
    private var lastMaintenance: Date?

    init(db: Database) throws {
        self.db = db
        try migrate()
    }

    private func migrate() throws {
        guard db.userVersion < Self.schemaVersion else { return }
        try db.execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS periods (
                start INTEGER NOT NULL,
                seconds INTEGER NOT NULL,
                state TEXT NOT NULL,
                rssi INTEGER,
                PRIMARY KEY (start, seconds)
            );
            CREATE TABLE IF NOT EXISTS aggregates (
                start INTEGER NOT NULL,
                seconds INTEGER NOT NULL,
                role TEXT NOT NULL,
                host TEXT NOT NULL,
                address TEXT NOT NULL,
                protocol TEXT NOT NULL,
                sent INTEGER NOT NULL,
                lost INTEGER NOT NULL,
                late INTEGER NOT NULL,
                median REAL,
                p95 REAL,
                jitter REAL,
                PRIMARY KEY (start, seconds, role, address, protocol)
            );
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                role TEXT NOT NULL,
                host TEXT NOT NULL,
                address TEXT NOT NULL,
                start REAL NOT NULL,
                end REAL NOT NULL,
                worst REAL
            );
            CREATE INDEX IF NOT EXISTS events_start ON events (start);
            """)
        db.userVersion = Self.schemaVersion
    }

    static func minute(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down)) * 60
    }

    static func hour(_ start: Int) -> Int {
        start - ((start % 3600) + 3600) % 3600
    }

    // MARK: - Recording

    /// Paused, locked, offline or measured, from now on.
    mutating func setState(_ state: MinuteState, now: Date) {
        self.state = state
        open[Self.minute(now), default: OpenMinute(state: state)].state = state
    }

    /// Makes sure the current minute has a row even when nothing is probed,
    /// and adds an RSSI sample to it.
    mutating func touch(now: Date, rssi: Int?) {
        let minute = Self.minute(now)
        open[minute, default: OpenMinute(state: state)].rssi += rssi.map { [$0] } ?? []
    }

    mutating func record(_ probe: ProbeRecord) {
        let key = Key(role: probe.target.role, host: probe.target.host, address: probe.target.address.description, probeProtocol: probe.probeProtocol)
        let time = probe.sentAt.timeIntervalSince1970
        let minute = Self.minute(probe.sentAt)
        var accumulator = open[minute]?.targets[key] ?? Accumulator()
        switch probe.outcome {
        case .reply(let rtt): accumulator.samples.append(.init(time: time, rtt: rtt))
        case .lost: accumulator.samples.append(.init(time: time, rtt: nil))
        case .late: accumulator.late += 1
        }
        open[minute, default: OpenMinute(state: state)].targets[key] = accumulator
    }

    mutating func record(_ event: NetworkEvent) {
        pendingEvents.append(event)
    }

    /// Minutes from `start` up to the minute `end` falls in are asleep, unless
    /// something was measured in them before the Mac went to sleep.
    mutating func markAsleep(from start: Date, to end: Date) {
        for minute in stride(from: Self.minute(start), to: Self.minute(end), by: 60) {
            open[minute, default: OpenMinute(state: .asleep)].state = .asleep
        }
    }

    // MARK: - Writing

    /// Writes the minutes that end by `through`, and pending events. Unless
    /// `force`, at most once a minute. Rolls up and prunes once an hour.
    mutating func flush(through: Date, now: Date, force: Bool = false) throws {
        if !force, let lastWrite, now.timeIntervalSince(lastWrite) < Self.writeInterval { return }
        let limit = through.timeIntervalSince1970
        let closed = open.keys.filter { Double($0 + 60) <= limit }.sorted()
        if !closed.isEmpty || !pendingEvents.isEmpty {
            try db.transaction {
                for minute in closed {
                    try write(minute, open[minute]!)
                }
                for event in pendingEvents {
                    try db.run(
                        "INSERT INTO events (kind, role, host, address, start, end, worst) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        [.text(event.kind.rawValue), .text(event.role.description), .text(event.host), .text(event.address.description),
                         .real(event.start.timeIntervalSince1970), .real(event.end.timeIntervalSince1970), .init(event.worstRTT)]
                    )
                }
            }
            for minute in closed { open[minute] = nil }
            pendingEvents.removeAll()
        }
        lastWrite = now
        if lastMaintenance.map({ now.timeIntervalSince($0) >= Self.maintenanceInterval }) ?? true {
            try rollUp(now: now)
            try prune(now: now)
            lastMaintenance = now
        }
    }

    private func write(_ start: Int, _ minute: OpenMinute) throws {
        let state = minute.targets.values.contains { !$0.samples.isEmpty } ? .measured : minute.state
        try writePeriod(start: start, seconds: 60, state: state, rssi: Self.median(minute.rssi))
        for (key, accumulator) in minute.targets {
            let samples = accumulator.samples.sorted { $0.time < $1.time }
            let replies = samples.compactMap(\.rtt).sorted()
            try writeAggregate(
                start: start, seconds: 60, key: key, sent: samples.count, lost: samples.count - replies.count, late: accumulator.late,
                median: TargetStats.nearestRank(0.5, of: replies), p95: TargetStats.nearestRank(0.95, of: replies),
                jitter: TargetStats.jitter(samples)
            )
        }
    }

    /// A minute written again (the app restarted within it, or a late reply
    /// came after it was written) keeps a measured state over any other.
    private func writePeriod(start: Int, seconds: Int, state: MinuteState, rssi: Int?) throws {
        try db.run("""
            INSERT INTO periods (start, seconds, state, rssi) VALUES (?, ?, ?, ?)
            ON CONFLICT (start, seconds) DO UPDATE SET
                state = CASE WHEN state = 'measured' THEN state ELSE excluded.state END,
                rssi = coalesce(rssi, excluded.rssi)
            """, [.init(start), .init(seconds), .text(state.rawValue), .init(rssi)])
    }

    /// Written again, the counts add up and the RTT figures come from whichever
    /// part had more replies.
    private func writeAggregate(start: Int, seconds: Int, key: Key, sent: Int, lost: Int, late: Int, median: Double?, p95: Double?, jitter: Double?) throws {
        try db.run("""
            INSERT INTO aggregates (start, seconds, role, host, address, protocol, sent, lost, late, median, p95, jitter)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (start, seconds, role, address, protocol) DO UPDATE SET
                median = CASE WHEN excluded.sent - excluded.lost > sent - lost THEN excluded.median ELSE median END,
                p95 = CASE WHEN excluded.sent - excluded.lost > sent - lost THEN excluded.p95 ELSE p95 END,
                jitter = CASE WHEN excluded.sent - excluded.lost > sent - lost THEN excluded.jitter ELSE jitter END,
                sent = sent + excluded.sent,
                lost = lost + excluded.lost,
                late = late + excluded.late
            """, [.init(start), .init(seconds), .text(key.role.description), .text(key.host), .text(key.address), .text(key.probeProtocol.rawValue),
                  .init(sent), .init(lost), .init(late), .init(median), .init(p95), .init(jitter)])
    }

    /// Minutes older than 7 days become hours. An hour's median is the median
    /// of its minutes' medians, its p95 the p95 of their p95s, and its jitter
    /// their mean weighted by replies. Its state is measured if any minute was,
    /// and otherwise the most common one.
    private func rollUp(now: Date) throws {
        let cutoff = Self.hour(Self.minute(now) - Self.minuteDetailDays * 86_400)
        let minutes = try aggregates(where: "seconds = 60 AND start < ?", [.init(cutoff)])
        var hours: [Int: [Key: [AggregateRow]]] = [:]
        for row in minutes {
            let key = Key(role: row.role, host: row.host, address: row.address, probeProtocol: row.probeProtocol)
            hours[Self.hour(Int(row.start.timeIntervalSince1970)), default: [:]][key, default: []].append(row)
        }
        let periods = try periods(where: "seconds = 60 AND start < ?", [.init(cutoff)])
        let periodsByHour = Dictionary(grouping: periods) { Self.hour(Int($0.start.timeIntervalSince1970)) }

        try db.transaction {
            for (hour, rows) in periodsByHour {
                let states = rows.map(\.state)
                let state = states.contains(.measured) ? .measured
                    : Dictionary(grouping: states, by: { $0 }).max { $0.value.count < $1.value.count }!.key
                try writePeriod(start: hour, seconds: 3600, state: state, rssi: Self.median(rows.compactMap(\.rssi)))
            }
            for (hour, targets) in hours {
                for (key, rows) in targets {
                    let replies = rows.map { $0.sent - $0.lost }
                    let jitters = zip(rows, replies).compactMap { row, count in row.jitter.map { ($0, Double(count)) } }
                    let weight = jitters.map(\.1).reduce(0, +)
                    try writeAggregate(
                        start: hour, seconds: 3600, key: key,
                        sent: rows.map(\.sent).reduce(0, +), lost: rows.map(\.lost).reduce(0, +), late: rows.map(\.late).reduce(0, +),
                        median: TargetStats.nearestRank(0.5, of: rows.compactMap(\.median).sorted()),
                        p95: TargetStats.nearestRank(0.95, of: rows.compactMap(\.p95).sorted()),
                        jitter: weight > 0 ? jitters.map { $0.0 * $0.1 }.reduce(0, +) / weight : nil
                    )
                }
            }
            try db.run("DELETE FROM aggregates WHERE seconds = 60 AND start < ?", [.init(cutoff)])
            try db.run("DELETE FROM periods WHERE seconds = 60 AND start < ?", [.init(cutoff)])
        }
    }

    private func prune(now: Date) throws {
        let cutoff = now.timeIntervalSince1970 - Double(retentionDays) * 86_400
        try db.run("DELETE FROM aggregates WHERE start + seconds <= ?", [.real(cutoff)])
        try db.run("DELETE FROM periods WHERE start + seconds <= ?", [.real(cutoff)])
        try db.run("DELETE FROM events WHERE end < ?", [.real(cutoff)])
    }

    static func median(_ values: [Int]) -> Int? {
        TargetStats.nearestRank(0.5, of: values.map(Double.init).sorted()).map { Int($0.rounded()) }
    }

    // MARK: - Reading

    /// Written periods overlapping the range, oldest first.
    func periods(from start: Date, to end: Date) throws -> [PeriodRow] {
        try periods(where: "start + seconds > ? AND start < ?", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)])
    }

    /// Written aggregates overlapping the range, oldest first, in plan order within a period.
    func aggregates(from start: Date, to end: Date) throws -> [AggregateRow] {
        try aggregates(where: "start + seconds > ? AND start < ?", [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)])
    }

    /// Written events overlapping the range, oldest first.
    func events(from start: Date, to end: Date) throws -> [NetworkEvent] {
        try db.query(
            "SELECT kind, role, host, address, start, end, worst FROM events WHERE end > ? AND start < ? ORDER BY start",
            [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]
        ).compactMap { row in
            guard let kind = row[0].string.flatMap(NetworkEvent.Kind.init), let role = row[1].string.flatMap(TargetRole.init),
                  let host = row[2].string, let address = row[3].string.flatMap(ProbeAddress.init),
                  let start = row[4].double, let end = row[5].double else { return nil }
            return NetworkEvent(kind: kind, role: role, host: host, address: address,
                                start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), worstRTT: row[6].double)
        }
    }

    private func periods(where condition: String, _ values: [Database.Value]) throws -> [PeriodRow] {
        try db.query("SELECT start, seconds, state, rssi FROM periods WHERE \(condition) ORDER BY start", values).compactMap { row in
            guard let start = row[0].int, let seconds = row[1].int, let state = row[2].string.flatMap(MinuteState.init) else { return nil }
            return PeriodRow(start: Date(timeIntervalSince1970: Double(start)), seconds: seconds, state: state, rssi: row[3].int)
        }
    }

    private func aggregates(where condition: String, _ values: [Database.Value]) throws -> [AggregateRow] {
        let rows = try db.query(
            "SELECT start, seconds, role, host, address, protocol, sent, lost, late, median, p95, jitter FROM aggregates WHERE \(condition)",
            values
        ).compactMap { row -> AggregateRow? in
            guard let start = row[0].int, let seconds = row[1].int, let role = row[2].string.flatMap(TargetRole.init),
                  let host = row[3].string, let address = row[4].string,
                  let probeProtocol = row[5].string.flatMap(ProbeEngine.ProbeProtocol.init),
                  let sent = row[6].int, let lost = row[7].int, let late = row[8].int else { return nil }
            return AggregateRow(start: Date(timeIntervalSince1970: Double(start)), seconds: seconds, role: role, host: host, address: address,
                                probeProtocol: probeProtocol, sent: sent, lost: lost, late: late,
                                median: row[9].double, p95: row[10].double, jitter: row[11].double)
        }
        return rows.sorted { ($0.start, $0.role.rank, $0.address) < ($1.start, $1.role.rank, $1.address) }
    }

    // MARK: - CSV export (PRD §6.4)

    static let aggregateColumns = "start,period_s,state,target,address,protocol,sent,lost,late,loss_pct,median_ms,p95_ms,jitter_ms,rssi_dbm"
    static let eventColumns = "start,end,duration_s,type,target,address,worst_rtt_ms"

    /// Every period in the range gets rows, so a gap is exported as the app
    /// not running, never as an outage. Ranges older than the per-minute
    /// detail are exported by the hour. The range ends at the current minute.
    func aggregatesCSV(from start: Date, to end: Date, now: Date) throws -> String {
        let format = formatter()
        let end = min(end.timeIntervalSince1970, Double(Self.minute(now)))
        let detailStart = Self.hour(Self.minute(now) - Self.minuteDetailDays * 86_400)
        let periods = try periods(from: start, to: Date(timeIntervalSince1970: end))
        let aggregates = Dictionary(grouping: try aggregates(from: start, to: Date(timeIntervalSince1970: end))) {
            Key2(start: Int($0.start.timeIntervalSince1970), seconds: $0.seconds)
        }
        let starts = periods.map { Int($0.start.timeIntervalSince1970) }
        var byStart: [Int: PeriodRow] = [:]
        for period in periods where byStart[Int(period.start.timeIntervalSince1970)].map({ $0.seconds < period.seconds }) ?? true {
            byStart[Int(period.start.timeIntervalSince1970)] = period
        }

        var lines = [Self.aggregateColumns]
        var time = Self.minute(start)
        if time < detailStart { time = Self.hour(time) }
        var next = 0
        while Double(time) < end {
            while next < starts.count, starts[next] < time { next += 1 }
            let date = format.string(from: Date(timeIntervalSince1970: Double(time)))
            if let period = byStart[time] {
                let rows = aggregates[Key2(start: time, seconds: period.seconds)] ?? []
                let rssi = period.rssi.map(String.init) ?? ""
                if rows.isEmpty {
                    lines.append("\(date),\(period.seconds),\(period.state.rawValue),,,,,,,,,,,\(rssi)")
                }
                for row in rows {
                    lines.append([
                        date, "\(period.seconds)", period.state.rawValue, Self.escape(row.host), row.address, row.probeProtocol.rawValue,
                        "\(row.sent)", "\(row.lost)", "\(row.late)", String(format: "%.1f", row.lossPercent),
                        Self.milliseconds(row.median), Self.milliseconds(row.p95), Self.milliseconds(row.jitter), rssi,
                    ].joined(separator: ","))
                }
                time += period.seconds
            } else {
                let nextStart = next < starts.count ? starts[next] : Int.max
                let seconds = time < detailStart && time % 3600 == 0 && nextStart >= time + 3600 ? 3600 : 60
                lines.append("\(date),\(seconds),\(MinuteState.notRunning.rawValue),,,,,,,,,,,")
                time += seconds
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func eventsCSV(from start: Date, to end: Date) throws -> String {
        let format = formatter()
        var lines = [Self.eventColumns]
        for event in try events(from: start, to: end) {
            lines.append([
                format.string(from: event.start), format.string(from: event.end), String(format: "%.1f", event.duration),
                event.kind.rawValue, Self.escape(event.host), event.address.description, Self.milliseconds(event.worstRTT),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private struct Key2: Hashable {
        let start: Int
        let seconds: Int
    }

    private func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? ""
    }

    private static func escape(_ field: String) -> String {
        field.contains(where: { ",\"\n".contains($0) }) ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }
}

/// The history database (PRD §6.4): per-minute aggregates for 7 days, hourly
/// after that, minute states, the event log, and CSV export. Safe to call from
/// any thread; the work runs on its own queue.
public final class History: @unchecked Sendable {
    /// `~/Library/Application Support/straylight/history.sqlite`
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "straylight/history.sqlite")
    }

    static let tickInterval = 10.0

    private let queue = DispatchQueue(label: "as.banast.straylight.history", qos: .utility)
    private let log = Logger(subsystem: "as.banast.straylight", category: "history")
    // Touched only on `queue`.
    private var store: HistoryStore
    private var timer: DispatchSourceTimer?
    private var sleepTotal = MachClock.sleepSinceBoot()

    /// `nil` keeps the history in memory only.
    public init(url: URL? = History.defaultURL) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        store = try HistoryStore(db: Database(path: url?.path(percentEncoded: false)))
    }

    /// 7, 30 or 90.
    public var retentionDays: Int {
        get { queue.sync { store.retentionDays } }
        set { queue.async { [self] in store.retentionDays = newValue } }
    }

    /// Starts the minute timer. `rssi` is sampled on every tick; it should return
    /// nil when the primary interface isn't Wi‑Fi.
    public func start(rssi: @escaping @Sendable () -> Int? = { nil }) {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .seconds(1))
            timer.setEventHandler { [unowned self] in tick(rssi: rssi()) }
            self.timer = timer
            timer.activate()
        }
    }

    /// Writes everything, including the minute in progress. Call before quitting.
    public func close() {
        queue.sync {
            timer?.cancel()
            timer = nil
            perform { try store.flush(through: .distantFuture, now: Date(), force: true) }
        }
    }

    public func record(_ probe: ProbeRecord) {
        queue.async { [self] in store.record(probe) }
    }

    public func record(_ event: NetworkEvent) {
        queue.async { [self] in store.record(event) }
    }

    /// Measured, offline, paused or locked, from now on. Asleep is noticed on its own.
    public func setState(_ state: MinuteState) {
        queue.async { [self] in
            guard state != store.state else { return }
            store.setState(state, now: Date())
        }
    }

    public func periods(from start: Date, to end: Date) throws -> [PeriodRow] {
        try queue.sync { try store.periods(from: start, to: end) }
    }

    public func aggregates(from start: Date, to end: Date) throws -> [AggregateRow] {
        try queue.sync { try store.aggregates(from: start, to: end) }
    }

    public func events(from start: Date, to end: Date) throws -> [NetworkEvent] {
        try queue.sync {
            try store.flush(through: Date(), now: Date(), force: true)
            return try store.events(from: start, to: end)
        }
    }

    /// The `aggregates` CSV, with timestamps in ISO 8601 with the local UTC offset.
    public func exportAggregates(from start: Date, to end: Date) throws -> String {
        try queue.sync {
            let now = Date()
            try store.flush(through: now, now: now, force: true)
            return try store.aggregatesCSV(from: start, to: end, now: now)
        }
    }

    public func exportEvents(from start: Date, to end: Date) throws -> String {
        try queue.sync {
            try store.flush(through: Date(), now: Date(), force: true)
            return try store.eventsCSV(from: start, to: end)
        }
    }

    private func tick(rssi: Int?) {
        let now = Date()
        let sleep = MachClock.sleepSinceBoot()
        if sleep > sleepTotal {
            let slept = MachClock.milliseconds(from: sleepTotal, to: sleep) / 1000
            sleepTotal = sleep
            if slept > 1 { store.markAsleep(from: now.addingTimeInterval(-slept), to: now) }
        }
        store.touch(now: now, rssi: rssi)
        perform { try store.flush(through: now.addingTimeInterval(-HistoryStore.grace), now: now) }
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            log.error("\(String(describing: error), privacy: .public)")
        }
    }
}
