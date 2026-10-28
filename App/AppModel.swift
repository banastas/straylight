import CoreWLAN
import Foundation
import Observation
import StraylightKit
import os

/// One probe in a trace: when it was sent, and its RTT in ms, nil when lost.
struct TraceSample: Equatable, Sendable {
    var sentAt: Date
    var rtt: Double?
}

/// Runs the monitor and the history store, and holds what the menu bar and
/// popover show. Pausing stops the monitor; resuming starts a fresh one, which
/// warms up again like any network change.
@MainActor
@Observable
final class AppModel {
    /// One trace point per pixel of the menu bar trace.
    static let traceLength = 28
    /// The popover's traces.
    nonisolated static let traceSeconds: TimeInterval = 60
    static let pauseDuration: TimeInterval = 3600
    static let wifiInterval: TimeInterval = 5

    private(set) var snapshot = MonitorSnapshot()
    private(set) var pausedUntil: Date?
    /// Every target's latest probes in send order: the last `traceSeconds`, and
    /// at least the last `traceLength` for the menu bar.
    private(set) var samples: [TargetRole: [TraceSample]] = [:]
    /// The latest outages and spikes, newest last.
    private(set) var recentEvents: [NetworkEvent] = []
    private(set) var offlineSince: Date?
    /// The Mac's address on the interface under any VPN.
    private(set) var localAddress: String?
    /// Read only while the popover is open, every `wifiInterval`.
    private(set) var wifi: WiFiInfo?
    /// The popover is open: Wi‑Fi readings are taken.
    var detailsVisible = false {
        didSet {
            guard detailsVisible != oldValue else { return }
            lastWiFiRead = nil
            if detailsVisible { readWiFiIfDue() } else { wifi = nil }
        }
    }

    /// Called after every snapshot and on pause or resume; the status item redraws from here.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let history: History?
    @ObservationIgnored private var monitor: Monitor?
    /// Updates from a stopped monitor can still be on their way to the main queue.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var resumeTimer: Timer?
    /// The Wi‑Fi interface carrying traffic, read on the history queue for RSSI.
    @ObservationIgnored private let wifiInterface = OSAllocatedUnfairLock<String?>(initialState: nil)
    @ObservationIgnored private var lastWiFiRead: Date?
    @ObservationIgnored private let log = Logger(subsystem: "as.banast.straylight", category: "app")

    init(preferences: Preferences) {
        self.preferences = preferences
        do {
            // For development, `STRAYLIGHT_HISTORY=<file>` uses another database.
            let url = ProcessInfo.processInfo.environment["STRAYLIGHT_HISTORY"].map { URL(fileURLWithPath: $0) } ?? History.defaultURL
            history = try History(url: url)
        } catch {
            history = nil
            log.error("history unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    var isPaused: Bool { pausedUntil != nil }

    /// The menu bar trace: the latest `traceLength` RTTs, oldest first.
    func menuBarTrace(_ role: TargetRole) -> [Double?] {
        (samples[role] ?? []).suffix(Self.traceLength).map(\.rtt)
    }

    /// Runs `body` off the main thread; nil without history or on an error.
    func readHistory<T: Sendable>(_ body: @escaping @Sendable (History) throws -> T) async -> T? {
        guard let history else { return nil }
        let log = log
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try body(history))
                } catch {
                    log.error("history read: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func start() {
        let wifiInterface = wifiInterface
        history?.start {
            guard let name = wifiInterface.withLock({ $0 }), let interface = CWWiFiClient.shared().interface(withName: name) else { return nil }
            let rssi = interface.rssiValue()
            return rssi == 0 ? nil : rssi
        }
        startMonitor()
    }

    /// Stops probing for an hour (PRD §6.6). The minutes are recorded as paused.
    func pause() {
        guard !isPaused else { return }
        stopMonitor()
        history?.setState(.paused)
        pausedUntil = Date().addingTimeInterval(Self.pauseDuration)
        resumeTimer = Timer.scheduledTimer(withTimeInterval: Self.pauseDuration, repeats: false) { _ in
            MainActor.assumeIsolated { self.resume() }
        }
        onChange?()
    }

    func resume() {
        guard isPaused else { return }
        resumeTimer?.invalidate()
        resumeTimer = nil
        pausedUntil = nil
        startMonitor()
        onChange?()
    }

    func update(interval: Double) {
        monitor?.update(interval: interval)
    }

    /// Before quitting: writes everything to disk.
    func shutdown() {
        stopMonitor()
        history?.close()
    }

    // MARK: - Monitor

    private func startMonitor() {
        generation += 1
        let generation = generation
        let history = history
        // Probes wait here and go to the main thread with the snapshot after
        // their round, so the main thread wakes once a round, not per probe.
        let pending = OSAllocatedUnfairLock<[(TargetRole, TraceSample)]>(initialState: [])
        let monitor = Monitor(settings: Self.targetSettings, interval: preferences.interval) { [weak self] update in
            // History takes everything straight from the engine's queue.
            switch update {
            case .probe(let probe):
                history?.record(probe)
                // Late replies were already counted as lost.
                if case .late = probe.outcome { return }
                let rtt: Double? = if case .reply(let milliseconds) = probe.outcome { milliseconds } else { nil }
                pending.withLock { $0.append((probe.target.role, TraceSample(sentAt: probe.sentAt, rtt: rtt))) }
            case .event(let event):
                history?.record(event)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.apply(event, generation: generation) }
                }
            case .snapshot(let snapshot):
                history?.setState(snapshot.path.isSatisfied ? .measured : .offline)
                let samples = pending.withLock { pending in
                    defer { pending.removeAll() }
                    return pending
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.apply(snapshot, samples: samples, generation: generation) }
                }
            }
        }
        self.monitor = monitor
        monitor.start()
    }

    /// Target settings arrive in M7. For development, `STRAYLIGHT_HOSTS`
    /// sets the internet hosts, such as `1.1.1.1,192.0.2.1` for one that
    /// never answers.
    private static var targetSettings: TargetSettings {
        var settings = TargetSettings()
        if let hosts = ProcessInfo.processInfo.environment["STRAYLIGHT_HOSTS"] {
            settings.internetHosts = hosts.split(separator: ",").map(String.init)
        }
        return settings
    }

    private func stopMonitor() {
        generation += 1
        monitor?.stop()
        monitor = nil
    }

    private func apply(_ event: NetworkEvent, generation: Int) {
        guard generation == self.generation else { return }
        recentEvents.append(event)
        if recentEvents.count > 10 { recentEvents.removeFirst() }
    }

    private func apply(_ snapshot: MonitorSnapshot, samples new: [(TargetRole, TraceSample)], generation: Int) {
        guard generation == self.generation else { return }
        let now = Date()
        for (role, sample) in new {
            var list = samples[role, default: []]
            // Losses are reported after the timeout, behind later replies.
            let index = list.lastIndex { $0.sentAt <= sample.sentAt }.map { $0 + 1 } ?? 0
            list.insert(sample, at: index)
            while list.count > Self.traceLength, let first = list.first, now.timeIntervalSince(first.sentAt) > Self.traceSeconds {
                list.removeFirst()
            }
            samples[role] = list
        }

        if snapshot.path != self.snapshot.path {
            localAddress = snapshot.path.physicalInterface.flatMap { LocalAddress.of(interface: $0) }
            wifiInterface.withLock { $0 = snapshot.path.kind == .wifi ? snapshot.path.physicalInterface : nil }
            if snapshot.path.kind != .wifi { wifi = nil }
        }
        if snapshot.path.isSatisfied {
            offlineSince = nil
        } else if offlineSince == nil {
            offlineSince = now
        }
        self.snapshot = snapshot
        readWiFiIfDue()
        onChange?()
    }

    /// For development: Wi‑Fi readings from `interface` whatever the path.
    func showWiFi(interface name: String) {
        wifi = WiFiInfo.read(interface: name)
    }

    private func readWiFiIfDue() {
        guard detailsVisible, snapshot.path.kind == .wifi, let name = snapshot.path.physicalInterface else { return }
        let now = Date()
        if let lastWiFiRead, now.timeIntervalSince(lastWiFiRead) < Self.wifiInterval - 0.5 { return }
        lastWiFiRead = now
        DispatchQueue.global(qos: .utility).async {
            let info = WiFiInfo.read(interface: name)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.detailsVisible else { return }
                    self.wifi = info
                }
            }
        }
    }
}
