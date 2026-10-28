import Foundation

/// The popover's history chart (PRD §6.7): one target's median, p95 and loss,
/// Wi‑Fi RSSI, and the minute states, in buckets narrow enough for its width.
public enum ChartRange: String, CaseIterable, Sendable, Identifiable {
    case hour, day, week

    public var id: Self { self }

    public var duration: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        }
    }

    /// 60 buckets of a minute, 144 of 10 minutes, 168 of an hour.
    public var bucketSeconds: Int {
        switch self {
        case .hour: 60
        case .day: 600
        case .week: 3600
        }
    }

    public var bucketCount: Int { Int(duration) / bucketSeconds }
}

public struct ChartBucket: Equatable, Sendable {
    public var start: Date
    /// Measured if any of it was, otherwise the state that covered most of it.
    /// nil while nothing in it has been written yet (the minute in progress).
    public var state: MinuteState?
    public var median: Double?
    public var p95: Double?
    /// nil when nothing was sent.
    public var lossPercent: Double?
    public var rssi: Int?

    public init(start: Date, state: MinuteState? = nil, median: Double? = nil, p95: Double? = nil, lossPercent: Double? = nil, rssi: Int? = nil) {
        self.start = start
        self.state = state
        self.median = median
        self.p95 = p95
        self.lossPercent = lossPercent
        self.rssi = rssi
    }
}

public enum HistoryChart {
    /// Buckets for `range` ending with the one that holds `now`, oldest first.
    /// Rows go in the bucket their period starts in. A bucket's median is the
    /// median of its rows' medians and its p95 the p95 of their p95s, the same
    /// approximation as the hourly rollups (PRD §6.4). Time with no period row
    /// counts as not running, except the minute in progress, which isn't
    /// written yet.
    public static func buckets(_ range: ChartRange, role: TargetRole, periods: [PeriodRow], aggregates: [AggregateRow], now: Date) -> [ChartBucket] {
        let size = range.bucketSeconds
        let nowSeconds = Int(now.timeIntervalSince1970.rounded(.down))
        let last = nowSeconds - nowSeconds % size
        let first = last - (range.bucketCount - 1) * size
        // Everything before the current minute has been written.
        let written = nowSeconds - nowSeconds % 60

        func index(_ date: Date) -> Int? {
            let seconds = Int(date.timeIntervalSince1970)
            guard seconds >= first, seconds < last + size else { return nil }
            return (seconds - first) / size
        }

        var stateSeconds = Array(repeating: [MinuteState: Int](), count: range.bucketCount)
        var rssi = Array(repeating: [Int](), count: range.bucketCount)
        for period in periods {
            guard let index = index(period.start) else { continue }
            stateSeconds[index][period.state, default: 0] += period.seconds
            if let value = period.rssi { rssi[index].append(value) }
        }

        var rows = Array(repeating: [AggregateRow](), count: range.bucketCount)
        for row in aggregates where row.role == role {
            if let index = index(row.start) { rows[index].append(row) }
        }

        return (0..<range.bucketCount).map { index in
            let start = first + index * size
            var bucket = ChartBucket(start: Date(timeIntervalSince1970: Double(start)))
            var seconds = stateSeconds[index]
            let covered = seconds.values.reduce(0, +)
            let finished = max(0, min(start + size, written) - start)
            if finished > covered { seconds[.notRunning, default: 0] += finished - covered }
            if seconds[.measured] != nil {
                bucket.state = .measured
            } else if let most = seconds.max(by: { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }) {
                bucket.state = most.key
            }

            let bucketRows = rows[index]
            bucket.median = TargetStats.nearestRank(0.5, of: bucketRows.compactMap(\.median).sorted())
            bucket.p95 = TargetStats.nearestRank(0.95, of: bucketRows.compactMap(\.p95).sorted())
            let sent = bucketRows.map(\.sent).reduce(0, +)
            if sent > 0 { bucket.lossPercent = 100 * Double(bucketRows.map(\.lost).reduce(0, +)) / Double(sent) }
            bucket.rssi = HistoryStore.median(rssi[index])
            return bucket
        }
    }
}
