import AppKit

@main
@MainActor
enum StraylightApp {
    // NSApplication holds its delegate weakly.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var model = AppModel(preferences: preferences)
    private var statusItem: StatusItemController?
    private var devChecks: DevChecks?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitCleanlyOnSIGTERM()
        model.start()
        statusItem = StatusItemController(model: model, preferences: preferences)
        statusItem?.showFirstRunIfNeeded()
        devChecks = DevChecks.startIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// `kill` and `launchctl` send SIGTERM, which would skip
    /// `applicationWillTerminate` and lose the history not yet written.
    private func quitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.activate()
        terminationSource = source
    }
}
