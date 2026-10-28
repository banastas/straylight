import AppKit
import OSLog
import StraylightKit
import UniformTypeIdentifiers

/// Export CSV from the popover (PRD §6.4): asks where to save, then writes.
@MainActor
enum CSVExport {
    enum Kind {
        case aggregates, events
    }

    enum Range: CaseIterable, Identifiable {
        case hour, day, week, all
        var id: Self { self }

        var title: String {
            switch self {
            case .hour: String(localized: "Last Hour")
            case .day: String(localized: "Last 24 Hours")
            case .week: String(localized: "Last 7 Days")
            case .all: String(localized: "Everything")
            }
        }

        /// Everything is the history retention period: an aggregates export has
        /// a row for every minute in its range, so it can't be open-ended.
        func start(now: Date, retentionDays: Int) -> Date {
            switch self {
            case .hour: now.addingTimeInterval(-3600)
            case .day: now.addingTimeInterval(-86_400)
            case .week: now.addingTimeInterval(-7 * 86_400)
            case .all: now.addingTimeInterval(-Double(retentionDays) * 86_400)
            }
        }
    }

    static func run(_ kind: Kind, _ range: Range, model: AppModel) {
        let panel = NSSavePanel()
        let day = Date().ISO8601Format(.init(timeZone: .current).year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "straylight-\(kind == .aggregates ? "measurements" : "events")-\(day).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let csv = await model.readHistory { history in
                    let now = Date()
                    let start = range.start(now: now, retentionDays: history.retentionDays)
                    return kind == .aggregates
                        ? try history.exportAggregates(from: start, to: now)
                        : try history.exportEvents(from: start, to: now)
                }
                do {
                    guard let csv else { throw CocoaError(.fileReadUnknown) }
                    try Data(csv.utf8).write(to: url, options: .atomic)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }
}

/// Copy diagnostics (PRD §6.11): versions, settings, targets, the last 50
/// events and the last 10 minutes of log lines, to the clipboard. The Mac's
/// own addresses aren't included.
@MainActor
enum Diagnostics {
    static func copy(model: AppModel, preferences: Preferences) async {
        let text = await text(model: model, preferences: preferences)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func text(model: AppModel, preferences: Preferences) async -> String {
        let header = summary(model: model, preferences: preferences)
        let events = await model.readHistory { try $0.latestEvents(limit: 50) } ?? []
        let log = await Task.detached(priority: .userInitiated) { recentLog() }.value

        var lines = header
        lines.append("")
        lines.append("events (latest 50, newest first):")
        lines += events.isEmpty ? ["  none"] : events.map { event in
            var line = "  \(iso(event.start)) \(event.kind.rawValue) \(event.host) \(event.address) \(String(format: "%.1f", event.duration)) s"
            if let worst = event.worstRTT { line += String(format: " worst %.1f ms", worst) }
            return line
        }
        lines.append("")
        lines.append("log (last 10 minutes):")
        lines += log.isEmpty ? ["  none"] : log.map { "  " + $0 }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func summary(model: AppModel, preferences: Preferences) -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let snapshot = model.snapshot
        let path = snapshot.path
        var lines = [
            "straylight \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: ""))",
            "time \(iso(Date()))",
            "settings style=\(preferences.displayStyle.rawValue) target=\(preferences.menuBarTarget.rawValue) interval=\(preferences.interval)s accent=\(preferences.accent.rawValue)",
            "verdict \(snapshot.verdict.rawValue)\(model.pausedUntil.map { " (paused until \(iso($0)))" } ?? "")\(snapshot.ipv6Problem ? ", IPv6 problem" : "")",
            "path satisfied=\(path.isSatisfied) kind=\(path.kind) interface=\(path.primaryInterface ?? "none") physical=\(path.physicalInterface ?? "none") vpn=\(path.isVPN) ipv4=\(path.hasIPv4) ipv6=\(path.hasIPv6) expensive=\(path.isExpensive) constrained=\(path.isConstrained)",
            "router ipv4=\(path.routerIPv4?.description ?? "none") ipv6=\(path.routerIPv6?.description ?? "none")",
            "",
            "targets:",
        ]
        if snapshot.targets.isEmpty { lines.append("  none") }
        for target in snapshot.targets {
            let metrics = target.metrics
            func ms(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
            var line = "  \(target.target.role) \(target.target.host) \(target.target.address) status=\(target.status) state=\(target.state)"
            line += " median=\(ms(metrics.median)) p95=\(ms(metrics.p95)) min=\(ms(metrics.baseline)) jitter=\(ms(metrics.jitter))"
            line += " sent=\(metrics.sent) lost=\(metrics.lost) late=\(metrics.late)"
            if target.answeredLocally { line += " answered-locally" }
            lines.append(line)
        }
        return lines
    }

    nonisolated private static func recentLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let position = store.position(date: Date().addingTimeInterval(-600))
        let predicate = NSPredicate(format: "subsystem == %@", "as.banast.straylight")
        guard let entries = try? store.getEntries(at: position, matching: predicate) else { return [] }
        return entries.compactMap { $0 as? OSLogEntryLog }.map {
            "\(iso($0.date)) [\($0.category)] \($0.composedMessage)"
        }
    }

    nonisolated private static func iso(_ date: Date) -> String {
        date.ISO8601Format(.init(timeZone: .current))
    }
}
