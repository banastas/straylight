import AppKit
import IOKit.ps

/// What the Mac is doing that changes how straylight probes (PRD §6.2): on
/// battery or in Low Power Mode it probes at the battery interval, and while
/// the screen is locked or the displays are asleep it stops.
///
/// For development, `STRAYLIGHT_ON_BATTERY=1` acts as if on battery, and
/// `STRAYLIGHT_LOCK_TEST=10,40` acts as if the screen locked 10 s after
/// launch and unlocked at 40 s.
@MainActor
final class SystemState {
    private(set) var onBattery = false
    private(set) var lowPowerMode = false
    private var screenLocked = false
    private var displaysAsleep = false
    private var simulatedLock = false

    var isLocked: Bool { screenLocked || displaysAsleep || simulatedLock }

    /// After any of the above changes.
    var onChange: (() -> Void)?

    private var powerSource: CFRunLoopSource?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let forceBattery = ProcessInfo.processInfo.environment["STRAYLIGHT_ON_BATTERY"] == "1"

    init() {
        onBattery = readOnBattery()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        screenLocked = Self.readScreenLocked()

        let context = Unmanaged.passUnretained(self).toOpaque()
        // Called on the main run loop when the power source or battery level changes.
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let state = Unmanaged<SystemState>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { state.set(\.onBattery, state.readOnBattery()) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) { state in
            state.set(\.lowPowerMode, ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.set(\.screenLocked, true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.set(\.screenLocked, false) }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.set(\.displaysAsleep, true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.set(\.displaysAsleep, false) }

        if let test = ProcessInfo.processInfo.environment["STRAYLIGHT_LOCK_TEST"]?.split(separator: ",").compactMap({ Double($0) }), test.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + test[0]) { self.set(\.simulatedLock, true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + test[1]) { self.set(\.simulatedLock, false) }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (SystemState) -> Void) {
        // Low Power Mode changes are posted on any thread.
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private func set(_ keyPath: ReferenceWritableKeyPath<SystemState, Bool>, _ value: Bool) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
        onChange?()
    }

    private func readOnBattery() -> Bool {
        if forceBattery { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    private static func readScreenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
