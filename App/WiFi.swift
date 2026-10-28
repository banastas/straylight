import CoreWLAN
import Darwin
import Foundation

/// The Wi‑Fi card's readings (PRD §6.5). The network name and BSSID aren't
/// read: they need Location permission.
struct WiFiInfo: Equatable, Sendable {
    /// dBm.
    var rssi: Int
    /// dBm.
    var noise: Int
    /// Mbit/s.
    var transmitRate: Double
    var channel: Int?
    /// "2.4 GHz", "5 GHz" or "6 GHz".
    var band: String?
    /// MHz.
    var width: Int?

    /// Signal to noise, in dB.
    var snr: Int? { noise == 0 ? nil : rssi - noise }

    /// Reads `interface`; nil when it isn't Wi‑Fi or isn't associated.
    static func read(interface name: String) -> WiFiInfo? {
        guard let interface = CWWiFiClient.shared().interface(withName: name), interface.powerOn() else { return nil }
        let rssi = interface.rssiValue()
        guard rssi != 0 else { return nil }
        let channel = interface.wlanChannel()
        return WiFiInfo(
            rssi: rssi,
            noise: interface.noiseMeasurement(),
            transmitRate: interface.transmitRate(),
            channel: channel.map(\.channelNumber),
            band: channel.flatMap { band($0.channelBand) },
            width: channel.flatMap { width($0.channelWidth) }
        )
    }

    private static func band(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
    }

    private static func width(_ width: CWChannelWidth) -> Int? {
        switch width {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: nil
        }
    }
}

enum LocalAddress {
    /// The Mac's IPv4 address on `interface`, or else its first global IPv6
    /// address. Shown in the popover header; never exported.
    static func of(interface name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var ipv6: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == name, let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET { return text }
            if ipv6 == nil, !text.hasPrefix("fe80") { ipv6 = text }
        }
        return ipv6
    }
}
