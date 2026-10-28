import Darwin
import Dispatch

/// Times TCP connects, for internet hosts that drop ICMP (PRD §6.2 Fallback).
/// The time runs from just before `connect` until the app sees the socket
/// become writable, so unlike the ICMP time it includes the app's own wake-up
/// latency. Each connection is closed as soon as it opens.
///
/// A refused connection counts as lost: it proves the host is reachable, but
/// it's also what a middlebox sends, so it isn't treated as a reply.
///
/// Everything runs on `queue`, like `ICMPProber`.
public final class TCPProber: @unchecked Sendable {
    private struct Attempt {
        let address: ProbeAddress
        let sequence: UInt16
        let sentAt: UInt64
        let source: DispatchSourceWrite
    }

    private let queue: DispatchQueue
    private let timeout: UInt64
    private let onResult: @Sendable (ProbeResult) -> Void
    private var nextSequence: UInt16 = 0
    private var attempts: [UInt16: Attempt] = [:]

    public init(queue: DispatchQueue, timeout: Double = 2, onResult: @escaping @Sendable (ProbeResult) -> Void) {
        self.queue = queue
        self.timeout = MachClock.ticks(seconds: timeout)
        self.onResult = onResult
    }

    deinit {
        for attempt in attempts.values { attempt.source.cancel() }
    }

    /// Returns the probe's sequence number, which its result carries. Results
    /// always arrive later, never during this call.
    @discardableResult
    public func probe(_ address: ProbeAddress, port: UInt16 = 443) throws -> UInt16 {
        dispatchPrecondition(condition: .onQueue(queue))
        let descriptor = socket(address.family == .v4 ? AF_INET : AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw ProbeError.socket(errno: errno) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        let sequence = nextSequence
        nextSequence &+= 1
        let sentAt = MachClock.now()
        let status = address.withSockaddr(port: port) { connect(descriptor, $0, $1) }
        let error = status == 0 ? 0 : errno

        switch error {
        case 0, EINPROGRESS:
            break
        case ECONNREFUSED:
            close(descriptor)
            queue.async { [onResult] in onResult(ProbeResult(address: address, sequence: sequence, sentAt: sentAt, outcome: .lost)) }
            return sequence
        default:
            close(descriptor)
            throw ProbeError.send(errno: error)
        }

        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        attempts[sequence] = Attempt(address: address, sequence: sequence, sentAt: sentAt, source: source)
        source.setEventHandler { [weak self] in self?.finish(sequence, descriptor: descriptor) }
        source.setCancelHandler { close(descriptor) }
        source.activate()
        return sequence
    }

    public func checkTimeouts() {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = MachClock.now()
        for attempt in attempts.values.sorted(by: { $0.sentAt < $1.sentAt }) where now > attempt.sentAt && now - attempt.sentAt > timeout {
            attempts[attempt.sequence] = nil
            attempt.source.cancel()
            onResult(ProbeResult(address: attempt.address, sequence: attempt.sequence, sentAt: attempt.sentAt, outcome: .lost))
        }
    }

    /// Abandons connects in flight without reporting them, for network changes.
    public func discardInFlight() {
        dispatchPrecondition(condition: .onQueue(queue))
        for attempt in attempts.values { attempt.source.cancel() }
        attempts.removeAll()
    }

    private func finish(_ sequence: UInt16, descriptor: Int32) {
        let now = MachClock.now()
        guard let attempt = attempts.removeValue(forKey: sequence) else { return }
        attempt.source.cancel()

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length)
        let outcome: ProbeResult.Outcome = error == 0 ? .reply(milliseconds: MachClock.milliseconds(from: attempt.sentAt, to: now)) : .lost
        onResult(ProbeResult(address: attempt.address, sequence: sequence, sentAt: attempt.sentAt, outcome: outcome))
    }
}
