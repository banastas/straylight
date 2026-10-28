import Darwin

/// What happened to one probe. Every probe produces exactly one `.reply` or
/// `.lost`; a `.late` can follow a `.lost` when the reply turns up after all.
public struct ProbeResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case reply(milliseconds: Double)
        /// No reply within the timeout.
        case lost
        /// A reply to a probe already reported as lost. Logged, not counted as received.
        case late(milliseconds: Double)
    }

    public let address: ProbeAddress
    public let sequence: UInt16
    /// `MachClock.now()` when the probe was sent.
    public let sentAt: UInt64
    public let outcome: Outcome
}

public enum ProbeError: Error, Equatable, CustomStringConvertible {
    case socket(errno: Int32)
    case send(errno: Int32)

    public var description: String {
        switch self {
        case .socket(let code): "socket: " + String(cString: strerror(code))
        case .send(let code): "send: " + String(cString: strerror(code))
        }
    }
}

/// In-flight probes and recent timeouts, keyed by sequence number. Kept apart
/// from the sockets so matching and timeouts can be tested on their own.
struct PendingProbes {
    struct Probe {
        let address: ProbeAddress
        let sequence: UInt16
        let token: UInt64
        let sentAt: UInt64
    }

    let timeout: UInt64
    /// How long a timed-out probe is remembered, so a reply to it shows as late.
    let lateWindow: UInt64
    private(set) var inFlight: [UInt16: Probe] = [:]
    private var timedOut: [UInt16: Probe] = [:]

    init(timeout: UInt64, lateWindow: UInt64) {
        self.timeout = timeout
        self.lateWindow = lateWindow
    }

    mutating func add(_ probe: Probe) {
        inFlight[probe.sequence] = probe
        timedOut[probe.sequence] = nil
    }

    /// Results for a reply. Replies from another address or with another token
    /// (someone else's ping on the same raw socket) are ignored. A reply that
    /// arrived after the timeout but before the timeout check counts as lost,
    /// then late, exactly as if the check had run first.
    mutating func match(_ echo: ICMPPacket.Echo, from address: ProbeAddress, receivedAt: UInt64) -> [ProbeResult] {
        if let probe = inFlight[echo.sequence], probe.token == echo.token, probe.address == address {
            inFlight[echo.sequence] = nil
            let milliseconds = MachClock.milliseconds(from: probe.sentAt, to: receivedAt)
            if receivedAt > probe.sentAt, receivedAt - probe.sentAt > timeout {
                return [result(probe, .lost), result(probe, .late(milliseconds: milliseconds))]
            }
            return [result(probe, .reply(milliseconds: milliseconds))]
        }
        if let probe = timedOut[echo.sequence], probe.token == echo.token, probe.address == address {
            timedOut[echo.sequence] = nil
            return [result(probe, .late(milliseconds: MachClock.milliseconds(from: probe.sentAt, to: receivedAt)))]
        }
        return []
    }

    /// Reports probes past the timeout as lost, oldest first, and forgets
    /// timeouts older than the late window.
    mutating func expire(now: UInt64) -> [ProbeResult] {
        let expired = inFlight.values.filter { now > $0.sentAt && now - $0.sentAt > timeout }.sorted { $0.sentAt < $1.sentAt }
        for probe in expired {
            inFlight[probe.sequence] = nil
            timedOut[probe.sequence] = probe
        }
        timedOut = timedOut.filter { now <= $0.value.sentAt || now - $0.value.sentAt <= lateWindow }
        return expired.map { result($0, .lost) }
    }

    /// Drops everything without reporting it, for network changes (PRD §6.2).
    mutating func discardAll() {
        inFlight.removeAll()
        timedOut.removeAll()
    }

    mutating func remove(sequence: UInt16) {
        inFlight[sequence] = nil
    }

    private func result(_ probe: Probe, _ outcome: ProbeResult.Outcome) -> ProbeResult {
        ProbeResult(address: probe.address, sequence: probe.sequence, sentAt: probe.sentAt, outcome: outcome)
    }
}
