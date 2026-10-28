import AppKit

/// Owns the status item. Until probing exists it shows a placeholder and a
/// menu with Quit; the rendered trace (M5) and the popover (M6) replace both.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()

        statusItem.autosaveName = "straylight"
        if let button = statusItem.button {
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = "—"
            button.setAccessibilityLabel(String(localized: "straylight: not measuring yet"))
        }

        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Quit straylight"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }
}
