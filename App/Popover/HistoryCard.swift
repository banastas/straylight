import StraylightKit
import SwiftUI

/// Median and p95 over 1 h, 24 h or 7 d, loss as bars under the baseline,
/// Wi‑Fi RSSI as a faint line, and the gaps shaded and labeled (PRD §6.7).
struct HistoryCard: View {
    let model: AppModel
    @Bindable var state: PopoverState
    @State private var buckets: [ChartBucket] = []
    @Environment(\.accent) private var accent

    var body: some View {
        Card(title: String(localized: "HISTORY")) {
            HStack {
                Picker(String(localized: "Target"), selection: $state.chartTarget) {
                    Text(String(localized: "internet")).tag(ChartTarget.internet)
                    Text(String(localized: "router")).tag(ChartTarget.router)
                }
                .frame(width: 130)
                Spacer()
                Picker(String(localized: "Range"), selection: $state.chartRange) {
                    Text("1h").tag(ChartRange.hour)
                    Text("24h").tag(ChartRange.day)
                    Text("7d").tag(ChartRange.week)
                }
                .frame(width: 120)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            ChartView(buckets: buckets, range: state.chartRange, floor: state.chartTarget == .router ? 2 : 10)
                .frame(height: 104)
            Legend(showRSSI: buckets.contains { $0.rssi != nil })
        }
        .task(id: "\(state.chartRange.rawValue)-\(state.chartTarget.rawValue)") {
            // Refreshed every minute while open, as finished minutes are written.
            while !Task.isCancelled {
                let (range, role) = (state.chartRange, state.chartTarget.role)
                if let loaded = await model.readHistory({ try $0.chart(range, role: role) }) {
                    buckets = loaded
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

private struct ChartView: View {
    let buckets: [ChartBucket]
    let range: ChartRange
    /// The RTT drawn at full height is never below this, in ms.
    let floor: Double
    @Environment(\.accent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    private static let lossHeight: CGFloat = 16
    private static let axisHeight: CGFloat = 11
    private static let labelHeight: CGFloat = 10
    /// Loss bars reach full height at this percentage.
    private static let lossScale = 10.0

    var body: some View {
        let peak = max(floor, buckets.compactMap(\.p95).max() ?? 0)
        let increased = contrast == .increased

        Canvas { context, size in
            let count = CGFloat(max(1, range.bucketCount))
            let width = size.width / count
            let lossTop = size.height - Self.axisHeight - Self.lossHeight
            // The top strip holds the scale label, clear of the lines.
            let plot = CGRect(x: 0, y: Self.labelHeight, width: size.width, height: lossTop - 2 - Self.labelHeight)
            func x(_ index: Int) -> CGFloat { (CGFloat(index) + 0.5) * width }
            func y(_ rtt: Double) -> CGFloat { plot.maxY - CGFloat(min(1, rtt / peak)) * (plot.height - 1) }

            // Gaps: shaded, with their state written in when there's room.
            for run in runs() where run.state != .measured {
                let rect = CGRect(x: CGFloat(run.range.lowerBound) * width, y: 0, width: CGFloat(run.range.count) * width, height: lossTop + Self.lossHeight)
                context.fill(Path(rect), with: .color(.secondary.opacity(increased ? 0.3 : 0.14)))
                let label = context.resolve(Text(run.state.label).font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary))
                if label.measure(in: rect.size).width + 4 <= rect.width {
                    context.draw(label, at: CGPoint(x: rect.midX, y: plot.midY), anchor: .center)
                }
            }

            // RSSI, faint, from −90 dBm at the bottom to −30 at the top.
            line(buckets.map { $0.rssi.map { CGFloat(max(0, min(1, (Double($0) + 90) / 60))) } }, x: x) { plot.maxY - $0 * (plot.height - 1) }
                .map { context.stroke($0, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
            line(buckets.map { $0.p95.map(y) }, x: x) { $0 }
                .map { context.stroke($0, with: .color(accent.opacity(increased ? 0.7 : 0.4)), style: StrokeStyle(lineWidth: 1, lineJoin: .round)) }
            line(buckets.map { $0.median.map(y) }, x: x) { $0 }
                .map { context.stroke($0, with: .color(accent), style: StrokeStyle(lineWidth: increased ? 2 : 1.5, lineJoin: .round)) }

            // Loss hangs below the baseline. Any loss gets at least a sliver.
            for (index, bucket) in buckets.enumerated() {
                guard let loss = bucket.lossPercent, loss > 0 else { continue }
                let height = max(1.5, CGFloat(min(1, loss / Self.lossScale)) * Self.lossHeight)
                context.fill(Path(CGRect(x: CGFloat(index) * width, y: lossTop, width: max(1, width - 0.5), height: height)), with: .color(.orange))
            }
            context.fill(Path(CGRect(x: 0, y: lossTop - 0.5, width: size.width, height: 0.5)), with: .color(.secondary.opacity(0.4)))

            let small = Font.system(size: 8, design: .monospaced)
            context.draw(Text(PopoverFormat.rtt(peak)).font(small).foregroundStyle(.tertiary), at: .zero, anchor: .topLeading)
            context.draw(Text(range.startLabel).font(small).foregroundStyle(.tertiary), at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
            context.draw(Text(String(localized: "now")).font(small).foregroundStyle(.tertiary), at: CGPoint(x: size.width, y: size.height), anchor: .bottomTrailing)
        }
        .accessibilityElement()
        .accessibilityLabel(summary)
    }

    /// A polyline through the values, broken where one is missing. A value
    /// with no neighbor gets a short flat stroke so it doesn't vanish.
    private func line(_ values: [CGFloat?], x: (Int) -> CGFloat, y: (CGFloat) -> CGFloat) -> Path? {
        var path = Path()
        let half = max(1, (x(1) - x(0)) / 2)
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            let point = CGPoint(x: x(index), y: y(value))
            let hasPrevious = index > 0 && values[index - 1] != nil
            let hasNext = index + 1 < values.count && values[index + 1] != nil
            if hasPrevious {
                path.addLine(to: point)
            } else if hasNext {
                path.move(to: point)
            } else {
                path.move(to: CGPoint(x: point.x - half, y: point.y))
                path.addLine(to: CGPoint(x: point.x + half, y: point.y))
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Consecutive buckets in the same state.
    private func runs() -> [(state: MinuteState, range: Range<Int>)] {
        var runs: [(state: MinuteState, range: Range<Int>)] = []
        for (index, bucket) in buckets.enumerated() {
            guard let state = bucket.state else { continue }
            if let last = runs.last, last.state == state, last.range.upperBound == index {
                runs[runs.count - 1].range = last.range.lowerBound..<index + 1
            } else {
                runs.append((state, index..<index + 1))
            }
        }
        return runs
    }

    /// For example "Median 6.8 milliseconds, p95 up to 12 milliseconds, loss 0.1 percent. Asleep 2 hours."
    private var summary: String {
        let medians = buckets.compactMap(\.median).sorted()
        guard !medians.isEmpty else { return String(localized: "No measurements in this range") }
        let median = medians[medians.count / 2]
        let p95 = buckets.compactMap(\.p95).max()
        let measured = buckets.filter { $0.lossPercent != nil }
        let loss = measured.isEmpty ? 0 : measured.compactMap(\.lossPercent).reduce(0, +) / Double(measured.count)
        var sentences = [String(localized: "Median \(PopoverFormat.spokenRTT(median)), p95 up to \(PopoverFormat.spokenRTT(p95)), loss \(PopoverFormat.percent(loss)).")]
        for state in [MinuteState.paused, .locked, .asleep, .offline, .notRunning] {
            let seconds = buckets.filter { $0.state == state }.count * range.bucketSeconds
            if seconds > 0 {
                sentences.append("\(state.label.capitalizedFirst) \(Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2))).")
            }
        }
        return sentences.joined(separator: " ")
    }
}

private struct Legend: View {
    let showRSSI: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            item(String(localized: "median")) { Rectangle().fill(accent).frame(width: 10, height: 1.5) }
            item("p95") { Rectangle().fill(accent.opacity(0.4)).frame(width: 10, height: 1) }
            item(String(localized: "loss")) { Rectangle().fill(.orange).frame(width: 4, height: 7) }
            if showRSSI {
                item(String(localized: "signal")) {
                    Path { $0.move(to: CGPoint(x: 0, y: 0.5)); $0.addLine(to: CGPoint(x: 10, y: 0.5)) }
                        .stroke(.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: 10, height: 1)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func item(_ label: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 4) {
            swatch()
            Text(label)
        }
    }
}

extension MinuteState {
    var label: String {
        switch self {
        case .measured: String(localized: "measured")
        case .paused: String(localized: "paused")
        case .locked: String(localized: "locked")
        case .asleep: String(localized: "asleep")
        case .offline: String(localized: "offline")
        case .notRunning: String(localized: "not running")
        }
    }
}

extension ChartRange {
    var startLabel: String {
        switch self {
        case .hour: String(localized: "−1h")
        case .day: String(localized: "−24h")
        case .week: String(localized: "−7d")
        }
    }
}
