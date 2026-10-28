import Darwin

public enum IPFamily: Sendable, Hashable {
    case v4, v6
}

/// A numeric IPv4 or IPv6 address, with the interface scope for link-local IPv6.
public struct ProbeAddress: Hashable, Sendable, CustomStringConvertible {
    public let family: IPFamily
    /// Network byte order: 4 bytes for IPv4, 16 for IPv6.
    public let bytes: [UInt8]
    public let scopeID: UInt32

    /// Parses a numeric address such as `"1.1.1.1"`, `"2606:4700:4700::1111"` or `"fe80::1%en0"`.
    public init?(_ string: String) {
        guard let address = Self.lookup(string, numericOnly: true).first else { return nil }
        self = address
    }

    /// Resolves a hostname or numeric address, IPv4 and IPv6 in the resolver's
    /// order. Blocks, so call it off the main thread.
    public static func resolve(_ host: String) -> [ProbeAddress] {
        lookup(host, numericOnly: false)
    }

    private static func lookup(_ host: String, numericOnly: Bool) -> [ProbeAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = numericOnly ? AI_NUMERICHOST : 0
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { return [] }
        defer { freeaddrinfo(list) }

        var addresses: [ProbeAddress] = []
        for entry in sequence(first: list, next: { $0.pointee.ai_next }) {
            if let sockaddr = entry.pointee.ai_addr, let address = ProbeAddress(sockaddr: sockaddr), !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses
    }

    init?(sockaddr pointer: UnsafePointer<sockaddr>) {
        let raw = UnsafeRawPointer(pointer)
        switch Int32(pointer.pointee.sa_family) {
        case AF_INET:
            let sin = raw.loadUnaligned(as: sockaddr_in.self)
            family = .v4
            bytes = withUnsafeBytes(of: sin.sin_addr) { Array($0) }
            scopeID = 0
        case AF_INET6:
            let sin6 = raw.loadUnaligned(as: sockaddr_in6.self)
            family = .v6
            bytes = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
            scopeID = sin6.sin6_scope_id
        default:
            return nil
        }
    }

    func withSockaddr<Result>(port: UInt16 = 0, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        switch family {
        case .v4:
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &sin.sin_addr) { $0.copyBytes(from: bytes) }
            return withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        case .v6:
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_port = port.bigEndian
            sin6.sin6_scope_id = scopeID
            withUnsafeMutableBytes(of: &sin6.sin6_addr) { $0.copyBytes(from: bytes) }
            return withUnsafePointer(to: &sin6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
    }

    public var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = bytes.withUnsafeBytes { inet_ntop(family == .v4 ? AF_INET : AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        var text = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        if scopeID != 0 {
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if if_indextoname(scopeID, &name) != nil {
                text += "%" + name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
        }
        return text
    }
}
