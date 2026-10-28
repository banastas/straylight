import CoreWLAN
import Foundation
import Observation
import StraylightKit
import os

/// Runs the monitor and the history store, and holds what the menu bar and
/// popover show. Pausing stops the monitor; resuming starts a fresh one, which
/// warms up again like any network change.
@MainActor
@Observable
final class AppModel {
    /// One trace point per pixel of the menu bar trace.
    static let traceLength = 28
    static let pauseDuration: TimeInterval = 3600

    private(set) var snapshot = MonitorSnapshot()
    private(set) var pausedUntil: Date?
    /// The latest RTTs of the router and the primary internet host, oldest
    /// first, nil for a lost probe. Up to `traceLength` each.
    private(set) var traces: [TargetRole: [Double?]] = [:]
    /// The latest outages and spikes, newest last.
    private(set) var recentEvents: [NetworkEvent] = []

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
    @ObservationIgnored private let log = Logger(subsystem: "as.banast.straylight", category: "app")

    init(preferences: Preferences) {
        self.preferences = preferences
        do {
            history = try History()
        } catch {
            history = nil
            log.error("history unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    var isPaused: Bool { pausedUntil != nil }

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
        let monitor = Monitor(interval: preferences.interval) { [weak self] update in
            // History takes everything straight from the engine's queue; the
            // main thread only sees what the menu bar and popover show.
            switch update {
            case .probe(let probe):
                history?.record(probe)
                guard probe.target.role == .router || probe.target.role == .internet(0) else { return }
            case .event(let event):
                history?.record(event)
            case .snapshot(let snapshot):
                history?.setState(snapshot.path.isSatisfied ? .measured : .offline)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(update, generation: generation) }
            }
        }
        self.monitor = monitor
        monitor.start()
    }

    private func stopMonitor() {
        generation += 1
        monitor?.stop()
        monitor = nil
    }

    private func apply(_ update: Monitor.Update, generation: Int) {
        guard generation == self.generation else { return }
        switch update {
        case .probe(let probe):
            let rtt: Double? = if case .reply(let milliseconds) = probe.outcome { milliseconds } else { nil }
            // Late replies were already counted as lost.
            if case .late = probe.outcome { return }
            traces[probe.target.role, default: []].append(rtt)
            if traces[probe.target.role]!.count > Self.traceLength { traces[probe.target.role]!.removeFirst() }
        case .event(let event):
            recentEvents.append(event)
            if recentEvents.count > 10 { recentEvents.removeFirst() }
        case .snapshot(let snapshot):
            self.snapshot = snapshot
            wifiInterface.withLock { $0 = snapshot.path.kind == .wifi ? snapshot.path.physicalInterface : nil }
            onChange?()
        }
    }
}
