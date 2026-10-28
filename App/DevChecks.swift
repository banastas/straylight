import CoreWLAN
import Foundation
import StraylightKit

/// A development-only check, run inside the app so it sees what the shipped
/// app will. `STRAYLIGHT_DEV_LOG=<file>` writes one Wi‑Fi snapshot: whether
/// CoreWLAN gives RSSI, noise, rate and channel without Location permission
/// (PRD §6.5). The M1 App Nap check that also lived here is done (§7.3).
final class DevChecks: @unchecked Sendable {
    private let queue = DispatchQueue(label: "as.banast.straylight.devchecks")
    private let log: FileHandle
    private let started = MachClock.now()

    static func startIfRequested() -> DevChecks? {
        guard let path = ProcessInfo.processInfo.environment["STRAYLIGHT_DEV_LOG"],
              FileManager.default.createFile(atPath: path, contents: nil),
              let log = FileHandle(forWritingAtPath: path) else { return nil }
        let checks = DevChecks(log: log)
        checks.queue.async { checks.logWiFi() }
        return checks
    }

    private init(log: FileHandle) {
        self.log = log
    }

    private func logWiFi() {
        guard let interface = CWWiFiClient.shared().interface() else {
            write("wifi none")
            return
        }
        let channel = interface.wlanChannel()
        write([
            "wifi interface=\(interface.interfaceName ?? "?")",
            "power=\(interface.powerOn())",
            "rssi=\(interface.rssiValue())",
            "noise=\(interface.noiseMeasurement())",
            "tx_rate=\(interface.transmitRate())",
            "channel=\(channel.map { String($0.channelNumber) } ?? "nil")",
            "band=\(channel.map { String($0.channelBand.rawValue) } ?? "nil")",
            "width=\(channel.map { String($0.channelWidth.rawValue) } ?? "nil")",
            // Both need Location permission; nil here means the app doesn't have it.
            "ssid=\(interface.ssid() ?? "nil")",
            "bssid=\(interface.bssid() ?? "nil")",
        ].joined(separator: " "))
    }

    private func write(_ line: String) {
        let seconds = MachClock.milliseconds(from: started, to: MachClock.now()) / 1000
        log.write(Data(String(format: "%9.3f %@\n", seconds, line).utf8))
    }
}
