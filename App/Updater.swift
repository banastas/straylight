import AppKit
import Observation
import Sparkle

/// Sparkle updates from https://straylight.banast.as/appcast.xml (see Info.plist).
///
/// For testing an update end to end without publishing, `STRAYLIGHT_FEED_URL`
/// points at another feed, but only one on this Mac (`http://localhost:…`),
/// and checks it in the background at launch.
@MainActor
@Observable
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// A version found by a scheduled check and not yet installed or
    /// dismissed: the popover footer shows it (PRD §6.7).
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        if Self.testFeedURL != nil { controller.updater.checkForUpdatesInBackground() }
    }

    nonisolated private static var testFeedURL: String? {
        guard let url = ProcessInfo.processInfo.environment["STRAYLIGHT_FEED_URL"],
              url.hasPrefix("http://localhost:") || url.hasPrefix("http://127.0.0.1:") else { return nil }
        return url
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        // straylight has no Dock icon; activate so Sparkle's window comes to the front.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Self.testFeedURL
    }

    // MARK: - SPUStandardUserDriverDelegate

    // Background apps opt in to gentle reminders; without this Sparkle warns
    // that a scheduled update alert may go unnoticed behind other apps.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.availableVersion = version
                // A scheduled check found an update: bring the alert forward.
                if handleShowingUpdate && !state.userInitiated { NSApp.activate() }
            }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.availableVersion = nil }
        }
    }
}
