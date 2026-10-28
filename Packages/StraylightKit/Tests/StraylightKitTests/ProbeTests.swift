import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import StraylightKit

@Suite struct ICMPPacketTests {
    @Test func checksumMatchesRFC1071Example() {
        #expect(ICMPPacket.checksum([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]) == 0x220d)
    }

    @Test func requestLayout() {
        let echo = ICMPPacket.Echo(identifier: 0x1234, sequence: 0xabcd, token: 0x0102_0304_0506_0708)
        let v4 = ICMPPacket.request(echo, family: .v4)
        #expect(v4.count == 64)
        #expect(v4[0] == 8)
        #expect(Array(v4[4..<16]) == [0x12, 0x34, 0xab, 0xcd, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(ICMPPacket.checksum(v4) == 0)

        let v6 = ICMPPacket.request(echo, family: .v6)
        #expect(v6[0] == 128)
        #expect(v6[2] == 0 && v6[3] == 0)
    }

    @Test func parsesRepliesWithAndWithoutIPHeader() {
        let echo = ICMPPacket.Echo(identifier: 7, sequence: 42, token: .max - 1)
        let reply = Self.reply(to: echo)
        #expect(ICMPPacket.reply(in: reply, family: .v4) == echo)

        var ipHeader = [UInt8](repeating: 0, count: 20)
        ipHeader[0] = 0x45
        ipHeader[9] = 1
        #expect(ICMPPacket.reply(in: ipHeader + reply, family: .v4) == echo)

        var v6 = ICMPPacket.request(echo, family: .v6)
        v6[0] = 129
        #expect(ICMPPacket.reply(in: v6, family: .v6) == echo)
    }

    @Test func rejectsOtherPackets() {
        let echo = ICMPPacket.Echo(identifier: 7, sequence: 42, token: 99)
        #expect(ICMPPacket.reply(in: ICMPPacket.request(echo, family: .v4), family: .v4) == nil)
        var corrupted = Self.reply(to: echo)
        corrupted[20] ^= 0xff
        #expect(ICMPPacket.reply(in: corrupted, family: .v4) == nil)
        #expect(ICMPPacket.reply(in: Array(Self.reply(to: echo)[..<12]), family: .v4) == nil)
    }

    /// What a host sends back: the request with type 0 and a new checksum.
    static func reply(to echo: ICMPPacket.Echo) -> [UInt8] {
        var packet = ICMPPacket.request(echo, family: .v4)
        packet[0] = 0
        packet[2] = 0
        packet[3] = 0
        let sum = ICMPPacket.checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)
        return packet
    }
}

@Suite struct PendingProbesTests {
    let router = ProbeAddress("192.168.1.1")!
    let other = ProbeAddress("192.168.1.2")!
    let second = MachClock.ticks(seconds: 1)

    func pending() -> PendingProbes {
        PendingProbes(timeout: 2 * second, lateWindow: 30 * second)
    }

    func echo(_ sequence: UInt16, token: UInt64 = 5) -> ICMPPacket.Echo {
        .init(identifier: 1, sequence: sequence, token: token)
    }

    @Test func replyWithinTimeout() throws {
        var pending = pending()
        pending.add(.init(address: router, sequence: 1, token: 5, sentAt: 1000))
        let results = pending.match(echo(1), from: router, receivedAt: 1000 + second / 100)
        #expect(results.count == 1)
        guard case .reply(let milliseconds) = try #require(results.first).outcome else { Issue.record("expected a reply"); return }
        #expect(abs(milliseconds - 10) < 0.01)
        #expect(pending.inFlight.isEmpty)
    }

    @Test func ignoresOtherTokensAndSources() {
        var pending = pending()
        pending.add(.init(address: router, sequence: 1, token: 5, sentAt: 1000))
        #expect(pending.match(echo(1, token: 6), from: router, receivedAt: 2000).isEmpty)
        #expect(pending.match(echo(1), from: other, receivedAt: 2000).isEmpty)
        #expect(pending.inFlight.count == 1)
    }

    @Test func timeoutThenLateReply() {
        var pending = pending()
        pending.add(.init(address: router, sequence: 1, token: 5, sentAt: 1000))
        #expect(pending.expire(now: 1000 + second).isEmpty)
        #expect(pending.expire(now: 1000 + 3 * second).map(\.outcome) == [.lost])
        let late = pending.match(echo(1), from: router, receivedAt: 1000 + 4 * second)
        #expect(late.count == 1)
        guard case .late = late.first?.outcome else { Issue.record("expected late"); return }
        #expect(pending.match(echo(1), from: router, receivedAt: 1000 + 5 * second).isEmpty)
    }

    @Test func replyPastTimeoutBeforeCheckIsLostThenLate() {
        var pending = pending()
        pending.add(.init(address: router, sequence: 1, token: 5, sentAt: 1000))
        let results = pending.match(echo(1), from: router, receivedAt: 1000 + 3 * second)
        #expect(results.count == 2)
        #expect(results.first?.outcome == .lost)
        guard case .late = results.last?.outcome else { Issue.record("expected late"); return }
    }

    @Test func lateWindowExpires() {
        var pending = pending()
        pending.add(.init(address: router, sequence: 1, token: 5, sentAt: 1000))
        _ = pending.expire(now: 1000 + 3 * second)
        _ = pending.expire(now: 1000 + 40 * second)
        #expect(pending.match(echo(1), from: router, receivedAt: 1000 + 41 * second).isEmpty)
    }

    @Test func discardReportsNothing() {
        var pending = pending()
        pending.add(.init(address: router, sequence: 1, token: 5, sentAt: 1000))
        pending.discardAll()
        #expect(pending.expire(now: 1000 + 3 * second).isEmpty)
        #expect(pending.match(echo(1), from: router, receivedAt: 1000 + second).isEmpty)
    }
}

@Suite struct ProbeAddressTests {
    @Test func parsesAndPrints() throws {
        #expect(ProbeAddress("1.1.1.1")?.description == "1.1.1.1")
        #expect(ProbeAddress("1.1.1.1")?.family == .v4)
        #expect(ProbeAddress("2606:4700:4700::1111")?.description == "2606:4700:4700::1111")
        let linkLocal = try #require(ProbeAddress("fe80::1%lo0"))
        #expect(linkLocal.scopeID == if_nametoindex("lo0"))
        #expect(linkLocal.description == "fe80::1%lo0")
        #expect(ProbeAddress("example.com") == nil)
    }
}

/// Real probes over loopback: proves the sockets open without root and the
/// reply path works end to end.
@Suite(.serialized) struct LiveProbeTests {
    final class Collector: Sendable {
        let results = Mutex<[ProbeResult]>([])
        let done = DispatchSemaphore(value: 0)

        func record(_ result: ProbeResult) {
            results.withLock { $0.append(result) }
            done.signal()
        }
    }

    @Test(arguments: ["127.0.0.1", "::1"])
    func icmpLoopback(address: String) throws {
        let queue = DispatchQueue(label: "test.icmp")
        let collector = Collector()
        let prober = ICMPProber(queue: queue) { collector.record($0) }
        let target = try #require(ProbeAddress(address))

        _ = try queue.sync { try prober.send(to: target) }
        #expect(collector.done.wait(timeout: .now() + 2) == .success)
        let result = try #require(collector.results.withLock { $0.first })
        guard case .reply(let milliseconds) = result.outcome else { Issue.record("expected a reply, got \(result.outcome)"); return }
        #expect(milliseconds > 0 && milliseconds < 50)
        #expect(result.address == target)
        queue.sync { prober.invalidate() }
    }

    @Test func tcpConnectsToListener() throws {
        let (listener, port) = try Self.listen()
        defer { close(listener) }
        let queue = DispatchQueue(label: "test.tcp")
        let collector = Collector()
        let prober = TCPProber(queue: queue) { collector.record($0) }

        _ = try queue.sync { try prober.probe(ProbeAddress("127.0.0.1")!, port: port) }
        #expect(collector.done.wait(timeout: .now() + 2) == .success)
        guard case .reply = collector.results.withLock({ $0.first?.outcome }) else { Issue.record("expected a reply"); return }
    }

    @Test func tcpRefusedIsLost() throws {
        let (listener, port) = try Self.listen()
        close(listener)
        let queue = DispatchQueue(label: "test.tcp.refused")
        let collector = Collector()
        let prober = TCPProber(queue: queue) { collector.record($0) }

        _ = try queue.sync { try prober.probe(ProbeAddress("127.0.0.1")!, port: port) }
        #expect(collector.done.wait(timeout: .now() + 2) == .success)
        #expect(collector.results.withLock { $0.first?.outcome } == .lost)
    }

    /// A listening socket on a free loopback port.
    static func listen() throws -> (Int32, UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(descriptor, pointer, length) == 0 && Darwin.listen(descriptor, 4) == 0 && getsockname(descriptor, pointer, &length) == 0
            }
        }
        guard bound else { throw ProbeError.socket(errno: errno) }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }
}
