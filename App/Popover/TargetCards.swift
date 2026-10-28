import StraylightKit
import SwiftUI

/// Trace floors, as in the menu bar: small jitter stays small.
private let routerFloor = 2.0
private let internetFloor = 10.0

struct RouterCard: View {
    let model: AppModel
    @Environment(\.accent) private var accent

    var body: some View {
        if let router = model.snapshot[.router] {
            switch router.status {
            case .doesntAnswerPing:
                Note(text: String(localized: "Router doesn't answer ping"), detail: router.target.address.description)
            case .unreachableVPN:
                Note(text: String(localized: "Router can't be reached through the VPN"), detail: router.target.address.description)
            default:
                Card(title: String(localized: "ROUTER"), subtitle: router.target.address.description,
                     value: headline(router), valueLabel: PopoverFormat.spokenRTT(router.metrics.latest)) {
                    TraceView(series: [.init(samples: model.samples[.router] ?? [], color: accent)], floor: routerFloor)
                        .frame(height: 40)
                    StatsRow(target: router)
                    StateLine(target: router, verdict: model.snapshot.verdict)
                }
            }
        } else if model.snapshot.path.isSatisfied, model.snapshot.verdict != .measuring {
            Note(text: String(localized: "No router on this network"), detail: nil)
        }
    }
}

struct InternetCard: View {
    let model: AppModel
    @Environment(\.accent) private var accent

    var body: some View {
        let snapshot = model.snapshot
        let hosts = snapshot.targets.filter { $0.target.role.isInternet }
        let primary = snapshot[.internet(0)]
        Card(title: String(localized: "INTERNET"), value: primary.map(headline) ?? "—",
             valueLabel: PopoverFormat.spokenRTT(primary?.metrics.latest)) {
            TraceView(series: [
                .init(samples: model.samples[.internet(0)] ?? [], color: accent),
                .init(samples: model.samples[.internet(1)] ?? [], color: accent.opacity(0.45)),
            ], floor: internetFloor)
            .frame(height: 40)
            if hosts.isEmpty {
                Text(snapshot.verdict == .measuring ? String(localized: "Measuring…") : String(localized: "No internet host resolved"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(hosts, id: \.target.role) { host in
                HostRow(target: host, isSecondary: host.target.role == .internet(1))
            }
        }
    }
}

struct CustomTargetCard: View {
    let model: AppModel
    let target: TargetSnapshot
    @Environment(\.accent) private var accent

    var body: some View {
        Card(title: target.target.host.uppercased(), subtitle: target.target.address.description,
             value: headline(target), valueLabel: PopoverFormat.spokenRTT(target.metrics.latest)) {
            TraceView(series: [.init(samples: model.samples[target.target.role] ?? [], color: accent)], floor: internetFloor)
                .frame(height: 32)
            StatsRow(target: target)
            StateLine(target: target, verdict: model.snapshot.verdict)
        }
    }
}

/// The latest reply, or `—` while warming up or down.
private func headline(_ target: TargetSnapshot) -> String {
    guard target.status != .warmingUp, target.state != .down else { return "—" }
    return PopoverFormat.rtt(target.metrics.latest)
}

private struct HostRow: View {
    let target: TargetSnapshot
    let isSecondary: Bool
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                // Matches the host's line in the trace.
                RoundedRectangle(cornerRadius: 1)
                    .fill(target.target.role == .internetIPv6 ? .clear : accent.opacity(isSecondary ? 0.45 : 1))
                    .frame(width: 8, height: 2)
                    .accessibilityHidden(true)
                Text(target.target.host)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if target.target.role == .internetIPv6 { Badge(text: "IPv6") }
                if target.status == .tcp { Badge(text: "TCP") }
                if target.answeredLocally { Badge(text: String(localized: "answered locally"), color: .orange) }
                Spacer()
                Text(headline(target))
                    .monospacedDigit()
                    .accessibilityLabel(PopoverFormat.spokenRTT(target.metrics.latest))
            }
            StatsRow(target: target)
            StateLine(target: target, verdict: nil)
        }
        .font(.caption)
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
    }
}

/// median · p95 · min · jitter · loss
private struct StatsRow: View {
    let target: TargetSnapshot

    var body: some View {
        // Cards show `—` while warming up (PRD §6.7).
        let metrics = target.status == .warmingUp ? Metrics() : target.metrics
        HStack(spacing: 8) {
            Stat(label: String(localized: "med"), value: number(metrics.median), spoken: PopoverFormat.spokenRTT(metrics.median))
            Stat(label: String(localized: "p95"), value: number(metrics.p95), spoken: PopoverFormat.spokenRTT(metrics.p95))
            Stat(label: String(localized: "min"), value: number(metrics.baseline), spoken: PopoverFormat.spokenRTT(metrics.baseline))
            Stat(label: String(localized: "jit"), value: number(metrics.jitter), spoken: PopoverFormat.spokenRTT(metrics.jitter))
            Spacer(minLength: 0)
            Stat(label: String(localized: "loss"), value: metrics.sent == 0 ? "—" : PopoverFormat.percent(metrics.lossPercent),
                 spoken: String(localized: "\(metrics.lost) of \(metrics.sent) lost"))
        }
        .font(.caption2)
        .lineLimit(1)
    }

    /// Without the unit, which the card's headline already shows.
    private func number(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        let text = PopoverFormat.rtt(milliseconds)
        return text.hasSuffix(" ms") ? String(text.dropLast(3)) : text.replacingOccurrences(of: " ", with: "")
    }
}

/// What the target's state means, when there's something to say.
private struct StateLine: View {
    let target: TargetSnapshot
    /// The router's note depends on the verdict; nil for internet hosts.
    let verdict: Verdict?

    var body: some View {
        if let text {
            Text(text)
                .font(.caption2)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String? {
        if target.status == .warmingUp { return String(localized: "Measuring…") }
        switch target.state {
        case .measuring:
            return String(localized: "Measuring…")
        case .ok:
            return nil
        case .down:
            let since = target.outageSince.map(PopoverFormat.time) ?? "?"
            return String(localized: "No reply since \(since)")
        case .bad(let problems):
            if target.target.role == .router, verdict == .good {
                return String(localized: "Slow to answer ping; traffic through it is fine")
            }
            var parts: [String] = []
            if problems.contains(.loss) { parts.append(String(localized: "losing probes")) }
            if problems.contains(.latency) { parts.append(String(localized: "slow")) }
            if problems.contains(.jitter) { parts.append(String(localized: "high jitter")) }
            return parts.formatted(.list(type: .and)).capitalizedFirst
        }
    }

    private var color: Color {
        switch target.state {
        case .down: .red
        case .bad: target.target.role == .router && verdict == .good ? .secondary : .orange
        default: .secondary
        }
    }
}

/// A one-line card for a router that can't be measured.
struct Note: View {
    let text: String
    let detail: String?

    var body: some View {
        HStack {
            Text(text)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .padding(10)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct OfflineCard: View {
    let since: Date?

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "wifi.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "No network"))
                .font(.headline)
            if let since {
                Text(String(localized: "Offline since \(PopoverFormat.time(since))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.fill.quinary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// The last minute of probes. A lost probe drops the line to the baseline
/// and gets a tick below it, so loss shows without relying on color.
struct TraceView: View {
    struct Series {
        var samples: [TraceSample]
        var color: Color
    }

    let series: [Series]
    /// The RTT drawn at full height is never below this, in ms.
    let floor: Double
    @Environment(\.colorSchemeContrast) private var contrast

    private static let lossBand: CGFloat = 5

    var body: some View {
        let now = Date()
        let start = now.addingTimeInterval(-AppModel.traceSeconds)
        let visible = series.map { Series(samples: $0.samples.filter { $0.sentAt >= start }, color: $0.color) }
        let peak = max(floor, visible.flatMap { $0.samples.compactMap(\.rtt) }.max() ?? 0)
        let lost = visible.first?.samples.filter { $0.rtt == nil }.count ?? 0
        let lineWidth: CGFloat = contrast == .increased ? 2 : 1.5

        Canvas { context, size in
            let plot = CGRect(x: 0, y: 0, width: size.width, height: size.height - Self.lossBand)
            func x(_ date: Date) -> CGFloat {
                plot.minX + CGFloat(date.timeIntervalSince(start) / AppModel.traceSeconds) * plot.width
            }
            for item in visible.reversed() {
                let points = item.samples.map { sample in
                    CGPoint(x: x(sample.sentAt), y: plot.maxY - CGFloat(min(1, (sample.rtt ?? 0) / peak)) * (plot.height - 1))
                }
                guard points.count > 1 else { continue }
                var line = Path()
                line.addLines(points)
                context.stroke(line, with: .color(item.color), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
            }
            // Ticks for lost probes, below the baseline.
            for (index, item) in visible.enumerated() {
                for sample in item.samples where sample.rtt == nil {
                    let rect = CGRect(x: x(sample.sentAt) - 0.75, y: plot.maxY + 1, width: 1.5, height: Self.lossBand - 1)
                    context.fill(Path(rect), with: .color(index == 0 ? .red : .red.opacity(0.5)))
                }
            }
            context.fill(Path(CGRect(x: 0, y: plot.maxY, width: size.width, height: 0.5)), with: .color(.secondary.opacity(0.4)))
            context.draw(Text(PopoverFormat.rtt(peak)).font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary),
                         at: CGPoint(x: 0, y: 0), anchor: .topLeading)
        }
        .accessibilityElement()
        .accessibilityLabel(lost == 0 ? String(localized: "None lost in the last minute") : String(localized: "\(lost) lost in the last minute"))
    }
}

extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
