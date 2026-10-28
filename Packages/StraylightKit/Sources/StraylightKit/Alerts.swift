import Foundation

/// When to notify (PRD §6.9): an internet outage once it has lasted 10 s and
/// again when it ends, and verdict changes that hold for 30 s. Fed every
/// snapshot; returns what to post. The verdict that first holds after launch
/// is the starting point and isn't posted.
public struct AlertTracker: Sendable {
    public enum Alert: Equatable, Sendable {
        /// `hosts` are the internet hosts that count, as configured; `verdict`
        /// says whether the router is down too.
        case internetDown(since: Date, hosts: [String], verdict: Verdict)
        case internetBack(after: TimeInterval)
        case verdict(Verdict)
    }

    public static let outageDelay: TimeInterval = 10
    public static let verdictHold: TimeInterval = 30

    public var outages: Bool
    public var verdictChanges: Bool

    private var downSince: Date?
    private var postedDown = false
    private var candidate: (verdict: Verdict, since: Date)?
    private var lastVerdict: Verdict?

    public init(outages: Bool = false, verdictChanges: Bool = false) {
        self.outages = outages
        self.verdictChanges = verdictChanges
    }

    /// After a pause or lock: an outage in progress is forgotten without an
    /// "internet back". The last verdict is kept, so the same verdict after
    /// resuming isn't posted again.
    public mutating func reset() {
        downSince = nil
        postedDown = false
        candidate = nil
    }

    public mutating func update(_ snapshot: MonitorSnapshot, now: Date) -> [Alert] {
        var alerts: [Alert] = []

        switch snapshot.internet {
        case .down:
            let hosts = snapshot.countedInternetHosts
            // Down once the last host went down.
            let since = downSince ?? hosts.compactMap(\.outageSince).max() ?? now
            downSince = since
            if outages, !postedDown, now.timeIntervalSince(since) >= Self.outageDelay {
                alerts.append(.internetDown(since: since, hosts: hosts.map(\.target.host), verdict: snapshot.verdict))
                postedDown = true
            }
        case .ok, .bad:
            if postedDown, let downSince {
                alerts.append(.internetBack(after: now.timeIntervalSince(downSince)))
                // So the return to Good isn't posted as well.
                lastVerdict = .good
            }
            downSince = nil
            postedDown = false
        case .measuring, nil:
            // Warm-up or offline: an outage in progress carries on until the internet is measured again.
            break
        }

        let verdict = snapshot.verdict
        guard verdict != .measuring else { return alerts }
        if candidate?.verdict != verdict { candidate = (verdict, now) }
        if let candidate, now.timeIntervalSince(candidate.since) >= Self.verdictHold, candidate.verdict != lastVerdict {
            // While an outage alert stands, it already says the internet is down.
            let covered = postedDown && [.internetDown, .localDown, .connectionDown].contains(candidate.verdict)
            if verdictChanges, lastVerdict != nil, !covered { alerts.append(.verdict(candidate.verdict)) }
            lastVerdict = candidate.verdict
        }
        return alerts
    }
}
