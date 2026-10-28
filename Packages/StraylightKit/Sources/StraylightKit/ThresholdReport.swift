import Foundation

/// How the "Bad" thresholds would have fired over recorded minutes, for
/// tuning them (PRD §6.3). A minute stands in for the window: at 1 s it holds
/// the same 60 probes; at slower rates the window is longer, so loss counts
/// here run lower than the window's.
public struct ThresholdReport: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// "router", or the host as configured, with " (IPv6)" for the IPv6 row.
        public var target: String
        public var thresholds: Thresholds
        /// Measured minutes.
        public var minutes: Int
        /// p50, p95 and p99 over the minutes.
        public var p95: [Double]
        public var jitter: [Double]
        public var lost: [Double]
        /// Minutes over each threshold.
        public var overLoss: Int
        public var overJitter: Int
        public var overP95: Int
        /// Minutes over any of them.
        public var bad: Int
    }

    public var lines: [Line]

    public static let quantiles = [0.5, 0.95, 0.99]

    public init(_ rows: [AggregateRow]) {
        let minutes = rows.filter { $0.seconds == 60 && $0.sent > 0 }
        var order: [String] = []
        var groups: [String: [AggregateRow]] = [:]
        for row in minutes {
            let key = Self.name(row)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        lines = order.map { key in
            let rows = groups[key]!
            let thresholds = rows[0].role == .router ? Thresholds.router : .internet
            func quantiles(_ values: [Double]) -> [Double] {
                let sorted = values.sorted()
                return Self.quantiles.map { TargetStats.nearestRank($0, of: sorted) ?? .nan }
            }
            let overLoss = rows.filter { $0.lost >= thresholds.lost }
            let overJitter = rows.filter { ($0.jitter ?? 0) > thresholds.jitter }
            let overP95 = rows.filter { ($0.p95 ?? 0) > thresholds.p95 }
            let bad = rows.filter { $0.lost >= thresholds.lost || ($0.jitter ?? 0) > thresholds.jitter || ($0.p95 ?? 0) > thresholds.p95 }
            return Line(
                target: key, thresholds: thresholds, minutes: rows.count,
                p95: quantiles(rows.compactMap(\.p95)), jitter: quantiles(rows.compactMap(\.jitter)),
                lost: quantiles(rows.map { Double($0.lost) }),
                overLoss: overLoss.count, overJitter: overJitter.count, overP95: overP95.count, bad: bad.count
            )
        }
    }

    private static func name(_ row: AggregateRow) -> String {
        switch row.role {
        case .router: "router"
        case .internetIPv6: "\(row.host) (IPv6)"
        case .internet, .custom: row.host
        }
    }

    /// A plain-text table.
    public var text: String {
        guard !lines.isEmpty else { return "no measured minutes\n" }
        func number(_ value: Double) -> String { value.isNaN ? "-" : String(format: value < 10 ? "%.1f" : "%.0f", value) }
        func percent(_ count: Int, _ total: Int) -> String { String(format: "%.1f%%", 100 * Double(count) / Double(total)) }
        var out = "per minute: p50 / p95 / p99, then the share of minutes over each threshold\n\n"
        for line in lines {
            let t = line.thresholds
            out += "\(line.target): \(line.minutes) minute\(line.minutes == 1 ? "" : "s"), \(percent(line.bad, line.minutes)) Bad\n"
            out += "  p95 ms    \(line.p95.map(number).joined(separator: " / "))   > \(number(t.p95)): \(percent(line.overP95, line.minutes))\n"
            out += "  jitter ms \(line.jitter.map(number).joined(separator: " / "))   > \(number(t.jitter)): \(percent(line.overJitter, line.minutes))\n"
            out += "  lost      \(line.lost.map(number).joined(separator: " / "))   ≥ \(t.lost): \(percent(line.overLoss, line.minutes))\n"
        }
        return out
    }
}
