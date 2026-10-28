import AppKit
import ImageIO
import Observation
import StraylightKit

/// Owns the status item: redraws it after every round of probes and opens a
/// small menu on click. The popover (M6) takes over the left click.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let preferences: Preferences
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private struct RenderKey: Equatable {
        var layout: MenuBarRenderer.Layout
        var appearance: NSAppearance.Name
        var scale: CGFloat
    }
    private var lastRender: RenderKey?
    private var lastAccessibilityLabel: String?

    /// Holds the rendered bitmap. Setting `button.image` instead makes NSButton
    /// re-render the image on the CPU every tick; a layer's contents go
    /// straight to the window server (flatline's PRD §7.4).
    private let contentLayer = CALayer()
    private static let horizontalPadding: CGFloat = 4

    init(model: AppModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
        super.init()

        statusItem.autosaveName = "straylight"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.wantsLayer = true
            contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            button.layer?.addSublayer(contentLayer)
        }

        model.onChange = { [weak self] in self?.redraw() }
        observePreferences()
        redraw()
    }

    private func redraw() {
        guard let button = statusItem.button else { return }
        // Once per round of probes, so cheap enough to refresh every time.
        let label = MenuBarRenderer.accessibilityLabel(model: model)
        if label != lastAccessibilityLabel {
            lastAccessibilityLabel = label
            button.setAccessibilityLabel(label)
        }

        let layout = MenuBarRenderer.layout(model: model, preferences: preferences)
        let appearance = button.effectiveAppearance
        let scale = button.window?.backingScaleFactor ?? 2
        let key = RenderKey(layout: layout, appearance: appearance.name, scale: scale)
        guard key != lastRender else { return }
        lastRender = key

        guard let image = MenuBarRenderer.image(for: layout, appearance: appearance, scale: scale) else { return }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let length = size.width + 2 * Self.horizontalPadding
        if statusItem.length != length { statusItem.length = length }
        contentLayer.contentsScale = scale
        contentLayer.frame = CGRect(
            x: Self.horizontalPadding,
            y: ((button.bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
        contentLayer.contents = image
        if let path = Self.snapshotPath { Self.writeSnapshot(image, to: path) }
    }

    /// Redraw as soon as a setting changes instead of waiting for the next round.
    private func observePreferences() {
        withObservationTracking {
            _ = preferences.displayStyle
            _ = preferences.menuBarTarget
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.redraw()
                self?.observePreferences()
            }
        }
    }

    // MARK: - Menu

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        showMenu()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let summary = menu.addItem(withTitle: model.isPaused ? (lastAccessibilityLabel ?? "") : model.snapshot.verdict.title, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(.separator())
        if model.isPaused {
            menu.addItem(withTitle: String(localized: "Resume"), action: #selector(resume), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: String(localized: "Pause for 1 Hour"), action: #selector(pause), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit straylight"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next click builds a fresh menu.
        statusItem.menu = nil
    }

    @objc private func pause() { model.pause() }
    @objc private func resume() { model.resume() }

    // MARK: - Development

    /// `STRAYLIGHT_SNAPSHOT=<file.png>` writes every rendered menu bar image to
    /// that file, for checking rendering without a screen capture.
    private static let snapshotPath = ProcessInfo.processInfo.environment["STRAYLIGHT_SNAPSHOT"]

    private static func writeSnapshot(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
