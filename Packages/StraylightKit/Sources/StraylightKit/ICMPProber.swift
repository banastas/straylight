import Darwin
import Dispatch

/// Sends ICMP echo requests over unprivileged datagram sockets and reports
/// each probe's outcome (PRD §6.2).
///
/// In xnu these sockets are raw sockets with the privilege check removed: the
/// IPv4 one sees every ICMP packet for the Mac, including replies to other
/// apps' pings, so replies are matched on sequence number, token and source.
/// The kernel doesn't rewrite the identifier, but nothing relies on that.
///
/// Everything runs on `queue`: call `send`, `checkTimeouts`, `discardInFlight`
/// and `invalidate` from it. `onResult` is called on it too.
public final class ICMPProber: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onResult: @Sendable (ProbeResult) -> Void
    private let identifier = UInt16.random(in: .min ... .max)
    private var nextSequence = UInt16.random(in: .min ... .max)
    private var pending: PendingProbes
    private var sockets: [IPFamily: ProbeSocket] = [:]

    public init(queue: DispatchQueue, timeout: Double = 2, onResult: @escaping @Sendable (ProbeResult) -> Void) {
        self.queue = queue
        self.onResult = onResult
        pending = PendingProbes(timeout: MachClock.ticks(seconds: timeout), lateWindow: MachClock.ticks(seconds: 30))
    }

    deinit {
        for socket in sockets.values { socket.source.cancel() }
    }

    /// Returns the probe's sequence number, which its result carries.
    @discardableResult
    public func send(to address: ProbeAddress) throws -> UInt16 {
        dispatchPrecondition(condition: .onQueue(queue))
        let socket = try socket(for: address.family)
        let sequence = nextSequence
        nextSequence &+= 1
        let token = UInt64.random(in: .min ... .max)
        let packet = ICMPPacket.request(.init(identifier: identifier, sequence: sequence, token: token), family: address.family)

        let sentAt = MachClock.now()
        let sent = address.withSockaddr { sockaddr, length in
            packet.withUnsafeBytes { sendto(socket.descriptor, $0.baseAddress, $0.count, 0, sockaddr, length) }
        }
        guard sent == packet.count else { throw ProbeError.send(errno: errno) }
        pending.add(.init(address: address, sequence: sequence, token: token, sentAt: sentAt))
        return sequence
    }

    /// Reports probes past the timeout as lost. Replies already waiting in the
    /// socket are read first, so a reply isn't counted lost because the timer
    /// fired before its read event.
    public func checkTimeouts() {
        dispatchPrecondition(condition: .onQueue(queue))
        for socket in sockets.values { drain(socket) }
        for result in pending.expire(now: MachClock.now()) { onResult(result) }
    }

    /// Forgets probes in flight without reporting them, for network changes.
    public func discardInFlight() {
        dispatchPrecondition(condition: .onQueue(queue))
        for socket in sockets.values { drain(socket) }
        pending.discardAll()
    }

    /// Closes the sockets. The next `send` opens them again.
    public func invalidate() {
        dispatchPrecondition(condition: .onQueue(queue))
        for socket in sockets.values { socket.source.cancel() }
        sockets.removeAll()
        pending.discardAll()
    }

    // MARK: - Sockets

    private struct ProbeSocket {
        let descriptor: Int32
        let family: IPFamily
        let source: DispatchSourceRead
    }

    private func socket(for family: IPFamily) throws -> ProbeSocket {
        if let socket = sockets[family] { return socket }

        let descriptor = switch family {
        case .v4: Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        case .v6: Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        }
        guard descriptor >= 0 else { throw ProbeError.socket(errno: errno) }

        var on: Int32 = 1
        let intSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &on, intSize)
        switch family {
        case .v4:
            setsockopt(descriptor, IPPROTO_IP, IP_STRIPHDR, &on, intSize)
        case .v6:
            // Wake only for echo replies, not router advertisements and neighbor discovery.
            var filter = icmp6_filter()
            withUnsafeMutableBytes(of: &filter.icmp6_filt) { words in
                let type = Int(ICMPPacket.replyType(.v6))
                words.storeBytes(of: UInt32(1) << (type & 31), toByteOffset: (type >> 5) * 4, as: UInt32.self)
            }
            setsockopt(descriptor, IPPROTO_ICMPV6, ICMP6_FILTER, &filter, socklen_t(MemoryLayout<icmp6_filter>.size))
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let socket = ProbeSocket(descriptor: descriptor, family: family, source: source)
        source.setEventHandler { [weak self] in self?.drain(socket) }
        source.setCancelHandler { close(descriptor) }
        source.activate()
        sockets[family] = socket
        return socket
    }

    private func drain(_ socket: ProbeSocket) {
        while let datagram = Self.receive(on: socket.descriptor) {
            guard let echo = ICMPPacket.reply(in: datagram.bytes, family: socket.family) else { continue }
            // A kernel stamp from the future would mean it isn't on our clock.
            let now = MachClock.now()
            let receivedAt = datagram.timestamp.map { min($0, now) } ?? now
            for result in pending.match(echo, from: datagram.source, receivedAt: receivedAt) {
                onResult(result)
            }
        }
    }

    private struct Datagram {
        let bytes: [UInt8]
        let source: ProbeAddress
        let timestamp: UInt64?
    }

    private static func receive(on descriptor: Int32) -> Datagram? {
        var bytes = [UInt8](repeating: 0, count: 1500)
        var control = [UInt8](repeating: 0, count: 64)
        var source = sockaddr_storage()

        let (count, timestamp) = bytes.withUnsafeMutableBytes { data in
            control.withUnsafeMutableBytes { control in
                withUnsafeMutablePointer(to: &source) { sourcePointer in
                    var vector = iovec(iov_base: data.baseAddress, iov_len: data.count)
                    return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                        var message = msghdr(
                            msg_name: UnsafeMutableRawPointer(sourcePointer),
                            msg_namelen: socklen_t(MemoryLayout<sockaddr_storage>.size),
                            msg_iov: vectorPointer,
                            msg_iovlen: 1,
                            msg_control: control.baseAddress,
                            msg_controllen: socklen_t(control.count),
                            msg_flags: 0
                        )
                        let count = recvmsg(descriptor, &message, 0)
                        guard count > 0 else { return (count, UInt64?.none) }
                        let used = UnsafeRawBufferPointer(rebasing: control[..<min(Int(message.msg_controllen), control.count)])
                        return (count, monotonicTimestamp(in: used))
                    }
                }
            }
        }
        guard count > 0 else { return nil }

        let address = withUnsafePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ProbeAddress(sockaddr: $0) }
        }
        guard let address else { return nil }
        return Datagram(bytes: Array(bytes[..<count]), source: address, timestamp: timestamp)
    }

    /// Finds `SCM_TIMESTAMP_MONOTONIC` in a control buffer. Swift can't use the
    /// CMSG macros; Darwin aligns headers and data to 4 bytes.
    static func monotonicTimestamp(in control: UnsafeRawBufferPointer) -> UInt64? {
        func align(_ length: Int) -> Int { (length + 3) & ~3 }
        let headerSize = MemoryLayout<cmsghdr>.size
        var offset = 0
        while offset + headerSize <= control.count {
            let header = control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            let length = Int(header.cmsg_len)
            guard length >= headerSize, offset + length <= control.count else { return nil }
            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_TIMESTAMP_MONOTONIC, length >= align(headerSize) + 8 {
                return control.loadUnaligned(fromByteOffset: offset + align(headerSize), as: UInt64.self)
            }
            offset += align(length)
        }
        return nil
    }
}
