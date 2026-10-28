import CoreWLAN
import Foundation
import StraylightKit

/// Development-only M1 checks, run inside the app so they see what the shipped
/// app will. `STRAYLIGHT_DEV_LOG=<file>` writes:
///
/// - one Wi‑Fi snapshot: whether CoreWLAN gives RSSI, noise, rate and channel
///   without Location permission (PRD §6.5)
/// - an ICMP probe to 1.1.1.1 every second with 10 % timer leeway, logging how
///   far apart the sends land, to see whether App Nap stretches the timer (§7.3)
///
/// The probe loop in M3 replaces the second part.
final class DevChecks: @unchecked Sendable {
    private let queue = DispatchQueue(label: "as.banast.straylight.devchecks")
    private let log: FileHandle
    private let started = MachClock.now()
    private var prober: ICMPProber?
    private var timer: DispatchSourceTimer?
    private var lastSend: UInt64?

    static func startIfRequested() -> DevChecks? {
        guard let path = ProcessInfo.processInfo.environment["STRAYLIGHT_DEV_LOG"],
              FileManager.default.createFile(atPath: path, contents: nil),
              let log = FileHandle(forWritingAtPath: path) else { return nil }
        let checks = DevChecks(log: log)
        checks.queue.async { checks.start() }
        return checks
    }

    private init(log: FileHandle) {
        self.log = log
    }

    private func start() {
        logWiFi()

        let target = ProbeAddress("1.1.1.1")!
        prober = ICMPProber(queue: queue) { [unowned self] result in
            switch result.outcome {
            case .reply(let milliseconds): write("reply rtt_ms=\(milliseconds)")
            case .lost: write("lost")
            case .late(let milliseconds): write("late rtt_ms=\(milliseconds)")
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [unowned self] in
            let now = MachClock.now()
            if let lastSend { write("send gap_ms=\(MachClock.milliseconds(from: lastSend, to: now))") }
            lastSend = now
            prober?.checkTimeouts()
            do { try prober?.send(to: target) } catch { write("send failed: \(error)") }
        }
        self.timer = timer
        timer.activate()
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
