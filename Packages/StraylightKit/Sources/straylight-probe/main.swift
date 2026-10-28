// straylight-probe: a development tool for checking the probers against
// `ping` (PRD §9). Not shipped in the app.
//
//   straylight-probe 1.1.1.1                  60 ICMP probes, 1 s apart
//   straylight-probe -c 20 -i 0.5 192.168.1.1
//   straylight-probe --tcp 1.1.1.1            TCP connect timing to port 443
//   straylight-probe --ttl 1 1.1.1.1          does Time Exceeded reach an unprivileged socket?
//   straylight-probe --path                   the network path and the targets planned for it
//   straylight-probe --watch 120              run the probe engine and print its events
//   straylight-probe --watch 30 --hosts github.com,8.8.8.8   with other internet hosts
//   straylight-probe --monitor 120 -i 5      stats, states and the verdict after each round
//   straylight-probe --monitor 600 --history /tmp/h.sqlite   also record history there
//   straylight-probe --export /tmp/h.sqlite 30               CSV of the last 30 minutes
//   straylight-probe --tune ~/Library/Application\ Support/straylight/history.sqlite 7
//                                             how the Bad thresholds fired over the last 7 days

import Darwin
import Dispatch
import Foundation
import StraylightKit

struct Options {
    var host = ""
    var count = 60
    var interval = 1.0
    var tcp = false
    var port: UInt16 = 443
    var ttl: Int32?
    var showPath = false
    var watch: Double?
    var monitor: Double?
    var history: String?
    var export: String?
    var tune: String?
    var hosts: [String]?

    init(_ arguments: [String]) {
        var arguments = arguments[...]
        while let argument = arguments.popFirst() {
            switch argument {
            case "-c": count = arguments.popFirst().flatMap(Int.init) ?? count
            case "-i": interval = arguments.popFirst().flatMap(Double.init) ?? interval
            case "--tcp": tcp = true
            case "--port": port = arguments.popFirst().flatMap(UInt16.init) ?? port
            case "--ttl": ttl = arguments.popFirst().flatMap(Int32.init)
            case "--path": showPath = true
            case "--hosts": hosts = arguments.popFirst()?.split(separator: ",").map(String.init)
            case "--watch": watch = arguments.popFirst().flatMap(Double.init) ?? 60
            case "--monitor": monitor = arguments.popFirst().flatMap(Double.init) ?? 60
            case "--history": history = arguments.popFirst()
            case "--export": export = arguments.popFirst()
            case "--tune": tune = arguments.popFirst()
            default: host = argument
            }
        }
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))

// MARK: - Path and engine (PRD §6.1, §7.3)

func describe(_ path: NetworkPath) -> String {
    [
        "satisfied=\(path.isSatisfied)",
        "primary=\(path.primaryInterface ?? "none")",
        "physical=\(path.physicalInterface ?? "none")",
        "kind=\(path.kind)",
        "vpn=\(path.isVPN)",
        "ipv4=\(path.hasIPv4)",
        "ipv6=\(path.hasIPv6)",
        "router4=\(path.routerIPv4?.description ?? "none")",
        "router6=\(path.routerIPv6?.description ?? "none")",
        "expensive=\(path.isExpensive)",
        "constrained=\(path.isConstrained)",
    ].joined(separator: " ")
}

if options.showPath {
    let path = PathMonitor.current()
    print(describe(path))
    for target in TargetPlan.targets(for: path, settings: TargetSettings()) {
        print("  \(target.role): \(target.host) → \(target.address)")
    }
    exit(0)
}

if let seconds = options.watch {
    let started = Date()
    var settings = TargetSettings()
    if let hosts = options.hosts { settings.internetHosts = hosts }
    let engine = ProbeEngine(settings: settings, interval: options.interval) { event in
        let time = String(format: "%7.2f", Date().timeIntervalSince(started))
        switch event {
        case .targets(let path, let targets):
            print("\(time) path \(describe(path))")
            for target in targets { print("\(time)   target \(target.role) \(target.address)") }
        case .status(let role, let status):
            print("\(time) status \(role) \(status)")
        case .result(let role, let probeProtocol, let result):
            let outcome = switch result.outcome {
            case .reply(let milliseconds): String(format: "%.3f ms", milliseconds)
            case .lost: "lost"
            case .late(let milliseconds): String(format: "late %.3f ms", milliseconds)
            }
            print("\(time) result \(role) \(probeProtocol) \(outcome)")
        case .tick:
            break
        }
    }
    engine.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        engine.stop()
        exit(0)
    }
    dispatchMain()
}

func ms(_ value: Double?) -> String {
    value.map { String(format: "%.2f", $0) } ?? "-"
}

if let path = options.export {
    let history = try History(url: URL(filePath: path))
    let minutes = Double(options.host) ?? 60
    let start = Date().addingTimeInterval(-minutes * 60)
    print(try history.exportAggregates(from: start, to: Date()), terminator: "")
    print(try history.exportEvents(from: start, to: Date()), terminator: "")
    exit(0)
}

if let path = options.tune {
    // Per-minute detail is kept for 7 days.
    let days = Double(options.host) ?? 7
    let history = try History(url: URL(filePath: path))
    print(ThresholdReport(try history.aggregates(from: Date().addingTimeInterval(-days * 86_400), to: Date())).text, terminator: "")
    exit(0)
}

if let seconds = options.monitor {
    let history = try options.history.map { try History(url: URL(filePath: $0)) }
    history?.start()
    let started = Date()
    var settings = TargetSettings()
    if let hosts = options.hosts { settings.internetHosts = hosts }
    let monitor = Monitor(settings: settings, interval: options.interval) { update in
        let time = String(format: "%7.2f", Date().timeIntervalSince(started))
        switch update {
        case .probe(let probe):
            history?.record(probe)
        case .snapshot(let snapshot):
            history?.setState(snapshot.path.isSatisfied ? .measured : .offline)
            var line = "\(time) \(snapshot.verdict)"
            if let internet = snapshot.internet { line += " internet=\(internet)" }
            if snapshot.ipv6Problem { line += " ipv6-problem" }
            print(line)
            for target in snapshot.targets {
                let m = target.metrics
                var detail = "\(target.status) \(target.state) now \(ms(m.latest)) med \(ms(m.median)) p95 \(ms(m.p95)) base \(ms(m.baseline)) jit \(ms(m.jitter)) lost \(m.lost)/\(m.sent)"
                if m.late > 0 { detail += " late \(m.late)" }
                if target.answeredLocally { detail += " answered-locally" }
                if let since = target.outageSince { detail += " down since \(String(format: "%.1f", since.timeIntervalSince(started))) s" }
                print("          \(target.target.role) \(target.target.address): \(detail)")
            }
        case .event(let event):
            history?.record(event)
            print("\(time) EVENT \(event.kind) \(event.role) \(event.address) at \(String(format: "%.1f", event.start.timeIntervalSince(started))) s for \(String(format: "%.1f", event.duration)) s" + (event.worstRTT.map { ", worst \(ms($0)) ms" } ?? ""))
        }
    }
    monitor.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        monitor.stop()
        history?.close()
        exit(0)
    }
    dispatchMain()
}

guard !options.host.isEmpty, let target = ProbeAddress.resolve(options.host).first else {
    print("usage: straylight-probe [-c count] [-i seconds] [--tcp [--port n]] [--ttl n] host")
    print("       straylight-probe --path | --watch [seconds] | --monitor [seconds] [-i seconds] [--hosts a,b]")
    exit(2)
}

func format(_ milliseconds: Double) -> String {
    String(format: "%.3f", milliseconds)
}

// MARK: - Time Exceeded check (PRD §13, hop-by-hop)

if let ttl = options.ttl {
    guard target.family == .v4 else { print("--ttl checks IPv4 only"); exit(2) }
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard descriptor >= 0 else { print("socket: \(String(cString: strerror(errno)))"); exit(1) }
    var value = ttl
    var on: Int32 = 1
    setsockopt(descriptor, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(descriptor, IPPROTO_IP, IP_STRIPHDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var wait = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

    let identifier = UInt16.random(in: .min ... .max)
    let packet = ICMPPacket.request(.init(identifier: identifier, sequence: 1, token: 1), family: .v4)
    var destination = sockaddr_in()
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    withUnsafeMutableBytes(of: &destination.sin_addr) { $0.copyBytes(from: target.bytes) }
    let sent = withUnsafePointer(to: &destination) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
            packet.withUnsafeBytes { sendto(descriptor, $0.baseAddress, $0.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    guard sent == packet.count else { print("send: \(String(cString: strerror(errno)))"); exit(1) }

    // Time Exceeded quotes the original IP header and the first 8 bytes of our ICMP header.
    var buffer = [UInt8](repeating: 0, count: 1500)
    var source = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    while true {
        let count = withUnsafeMutablePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 0 else { print("no Time Exceeded within 2 s"); exit(1) }
        var bytes = Array(buffer[..<count])
        if bytes[0] >> 4 == 4 { bytes.removeFirst(Int(bytes[0] & 0x0f) * 4) }
        guard bytes.count >= 8 + 20 + 8, bytes[0] == 11 else { continue }
        let quoted = 8 + Int(bytes[8] & 0x0f) * 4
        guard bytes.count >= quoted + 8, UInt16(bytes[quoted + 4]) << 8 | UInt16(bytes[quoted + 5]) == identifier else { continue }
        let from = withUnsafePointer(to: &source.sin_addr) { String(cString: inet_ntoa($0.pointee)) }
        print("Time Exceeded from \(from) at TTL \(ttl): an unprivileged socket receives it")
        exit(0)
    }
}

// MARK: - Probe run

final class Run: @unchecked Sendable {
    let options: Options
    let target: ProbeAddress
    let queue = DispatchQueue(label: "straylight-probe")
    var results: [ProbeResult] = []
    var sent = 0
    var icmp: ICMPProber?
    var tcp: TCPProber?
    var timer: DispatchSourceTimer?

    init(options: Options, target: ProbeAddress) {
        self.options = options
        self.target = target
    }

    func record(_ result: ProbeResult) {
        switch result.outcome {
        case .reply(let milliseconds): print("seq \(result.sequence): \(format(milliseconds)) ms")
        case .lost: print("seq \(result.sequence): lost")
        case .late(let milliseconds): print("seq \(result.sequence): late, \(format(milliseconds)) ms")
        }
        results.append(result)
    }

    func start() {
        if options.tcp {
            tcp = TCPProber(queue: queue) { [unowned self] in record($0) }
        } else {
            icmp = ICMPProber(queue: queue) { [unowned self] in record($0) }
        }
        print("probing \(target) \(options.tcp ? "with TCP to port \(options.port)" : "with ICMP"), \(options.count) × \(options.interval) s")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: options.interval, leeway: .milliseconds(Int(options.interval * 100)))
        timer.setEventHandler { [unowned self] in tick() }
        self.timer = timer
        timer.activate()
    }

    func tick() {
        icmp?.checkTimeouts()
        tcp?.checkTimeouts()
        guard sent < options.count else {
            if results.count >= sent || results.allSatisfy({ MachClock.milliseconds(from: $0.sentAt, to: MachClock.now()) > 2500 }) {
                summarize()
                exit(0)
            }
            return
        }
        do {
            if let icmp { try icmp.send(to: target) }
            if let tcp { try tcp.probe(target, port: options.port) }
        } catch {
            print("send failed: \(error)")
        }
        sent += 1
    }

    func summarize() {
        let counted = results.filter { if case .late = $0.outcome { false } else { true } }.sorted { $0.sentAt < $1.sentAt }
        let rtts = counted.compactMap { if case .reply(let milliseconds) = $0.outcome { milliseconds } else { nil } }
        let lost = counted.count - rtts.count
        let late = results.count - counted.count
        print("--- \(target): \(counted.count) sent, \(rtts.count) received, \(lost) lost, \(late) late, \(String(format: "%.1f", 100 * Double(lost) / Double(max(1, counted.count))))% loss")
        guard !rtts.isEmpty else { return }

        let sorted = rtts.sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let p95 = sorted[Int((0.95 * Double(sorted.count)).rounded(.up)) - 1]
        // Mean |ΔRTT| between consecutive replies, skipping pairs split by a loss (PRD §6.3).
        var differences: [Double] = []
        for (previous, next) in zip(counted, counted.dropFirst()) {
            if case .reply(let a) = previous.outcome, case .reply(let b) = next.outcome { differences.append(abs(b - a)) }
        }
        let jitter = differences.isEmpty ? 0 : differences.reduce(0, +) / Double(differences.count)
        print("rtt min/median/p95/max = \(format(sorted.first!))/\(format(median))/\(format(p95))/\(format(sorted.last!)) ms, jitter \(format(jitter)) ms")
    }
}

let run = Run(options: options, target: target)
run.queue.async { run.start() }
dispatchMain()
