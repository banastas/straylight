import Foundation
import StraylightKit
import UserNotifications

/// Posts the opt-in notifications (PRD §6.9). `AlertTracker` decides when;
/// this asks for permission and writes the text. Clicking one opens the popover.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks the first time a notification setting is turned on. False when
    /// notifications are turned off for straylight in System Settings.
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ alert: AlertTracker.Alert, snapshot: MonitorSnapshot) {
        let content = UNMutableNotificationContent()
        switch alert {
        case .internetDown(let since, let hosts, let verdict):
            content.title = String(localized: "Internet down")
            let names = hosts.formatted(.list(type: .and))
            var body = String(localized: "No reply from \(names) since \(PopoverFormat.time(since)).")
            if verdict == .localDown { body += " " + String(localized: "The router isn't answering either.") }
            content.body = body
            content.sound = .default
        case .internetBack(let after):
            content.title = String(localized: "Internet back")
            content.body = String(localized: "It was down for \(PopoverFormat.duration(after)).")
        case .verdict(let verdict):
            content.title = verdict.title
            content.body = snapshot.verdictDetail(offlineSince: nil) ?? ""
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { onOpen?() }
    }
}
