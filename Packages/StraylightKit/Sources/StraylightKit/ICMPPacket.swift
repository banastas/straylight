/// ICMP echo packets as straylight sends them: the 8-byte ICMP header, then a
/// 56-byte payload that starts with a random 8-byte token (PRD §6.2).
public enum ICMPPacket {
    public static let headerSize = 8
    public static let payloadSize = 56

    public struct Echo: Equatable, Sendable {
        public var identifier: UInt16
        public var sequence: UInt16
        public var token: UInt64

        public init(identifier: UInt16, sequence: UInt16, token: UInt64) {
            self.identifier = identifier
            self.sequence = sequence
            self.token = token
        }
    }

    static func requestType(_ family: IPFamily) -> UInt8 { family == .v4 ? 8 : 128 }
    static func replyType(_ family: IPFamily) -> UInt8 { family == .v4 ? 0 : 129 }

    /// An echo request. The IPv4 checksum is filled in here; the kernel
    /// computes ICMPv6 checksums itself.
    public static func request(_ echo: Echo, family: IPFamily) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: headerSize + payloadSize)
        packet[0] = requestType(family)
        write(echo, into: &packet)
        for index in (headerSize + 8)..<packet.count {
            packet[index] = UInt8(truncatingIfNeeded: index)
        }
        if family == .v4 {
            put(checksum(packet), into: &packet, at: 2)
        }
        return packet
    }

    /// The echo reply in a received datagram, or nil for anything else. IPv4
    /// datagram sockets are raw sockets underneath and may deliver the IP
    /// header first; it's skipped when present.
    public static func reply(in datagram: [UInt8], family: IPFamily) -> Echo? {
        var packet = datagram[...]
        if family == .v4, let first = packet.first, first >> 4 == 4 {
            let headerLength = Int(first & 0x0f) * 4
            guard headerLength >= 20, packet.count >= headerLength + headerSize, packet[packet.startIndex + 9] == 1 else { return nil }
            packet = packet.dropFirst(headerLength)
        }
        let icmp = Array(packet)
        guard icmp.count >= headerSize + 8, icmp[0] == replyType(family), icmp[1] == 0 else { return nil }
        if family == .v4, checksum(icmp) != 0 { return nil }
        return Echo(
            identifier: UInt16(icmp[4]) << 8 | UInt16(icmp[5]),
            sequence: UInt16(icmp[6]) << 8 | UInt16(icmp[7]),
            token: icmp[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
        )
    }

    /// The Internet checksum (RFC 1071). Over a packet that already holds its
    /// checksum, the result is zero.
    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(sum)
    }

    static func write(_ echo: Echo, into packet: inout [UInt8]) {
        put(echo.identifier, into: &packet, at: 4)
        put(echo.sequence, into: &packet, at: 6)
        for index in 0..<8 {
            packet[headerSize + index] = UInt8(truncatingIfNeeded: echo.token >> (56 - 8 * index))
        }
    }

    private static func put(_ value: UInt16, into packet: inout [UInt8], at offset: Int) {
        packet[offset] = UInt8(value >> 8)
        packet[offset + 1] = UInt8(truncatingIfNeeded: value)
    }
}
