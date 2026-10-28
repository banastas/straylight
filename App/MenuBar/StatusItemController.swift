import AppKit
import CoreWLAN
import ImageIO
import Observation
import StraylightKit
import SwiftUI

/// Owns the status item: redraws it after every round of probes, opens the
/// popover on click and a small menu on right-click or Control-click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let model: AppModel
    private let preferences: Preferences
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// Created per opening and released on close: a kept NSPopover holds on to
    /// its window and backing surfaces long after it's hidden (as in flatline).
    private var popover: NSPopover?
    private var popoverOpened: Date?
    private let popoverState = PopoverState()
    /// The first-run note counts as seen once it has been open this long, so
    /// a popover that closes at once (the app didn't get focus) shows it again.
    private static let firstRunSeenAfter: TimeInterval = 3

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
        if let path = Self.popoverSnapshotPath { schedulePopoverSnapshot(to: path) }
    }

    /// The first-run note (PRD §6.8), once the status item is on screen.
    func showFirstRunIfNeeded() {
        guard !preferences.didShowFirstRun else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            popoverState.showingFirstRun = true
            if popover?.isShown != true { togglePopover(settings: false) }
        }
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
            _ = preferences.interval
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.model.update(interval: self.preferences.interval)
                self.redraw()
                self.observePreferences()
            }
        }
    }

    // MARK: - Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover(settings: false)
        }
    }

    private func togglePopover(settings: Bool) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }

        if settings { popoverState.showingSettings = true }
        let actions = PopoverActions(
            export: { [weak self] kind, range in
                guard let self else { return }
                self.popover?.performClose(nil)
                CSVExport.run(kind, range, model: self.model)
            },
            copyDiagnostics: { [model, preferences] in await Diagnostics.copy(model: model, preferences: preferences) },
            dismissFirstRun: { [weak self] in self?.dismissFirstRun() }
        )
        let controller = NSHostingController(rootView: PopoverView(model: model, preferences: preferences, state: popoverState, actions: actions))
        controller.sizingOptions = .preferredContentSize

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = controller
        self.popover = popover

        model.detailsVisible = true
        popoverOpened = Date()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without key status the popover draws its controls inactive.
        controller.view.window?.makeKey()
    }

    private func dismissFirstRun() {
        popoverState.showingFirstRun = false
        preferences.didShowFirstRun = true
    }

    func popoverDidClose(_ notification: Notification) {
        model.detailsVisible = false
        if popoverState.showingFirstRun, let popoverOpened, Date().timeIntervalSince(popoverOpened) >= Self.firstRunSeenAfter {
            dismissFirstRun()
        }
        // Release the popover, its window and the SwiftUI tree once AppKit has
        // finished closing it, then hand the freed pages back to the system.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover?.isShown != true else { return }
            self.popover = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let summary = menu.addItem(withTitle: model.isPaused ? (lastAccessibilityLabel ?? "") : model.snapshot.verdict.title, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Open straylight"), action: #selector(openPopover), keyEquivalent: "").target = self
        if model.isPaused {
            menu.addItem(withTitle: String(localized: "Resume"), action: #selector(resume), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: String(localized: "Pause for 1 Hour"), action: #selector(pause), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit straylight"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left-click goes back to the popover.
        statusItem.menu = nil
    }

    @objc private func openPopover() { togglePopover(settings: false) }
    @objc private func openSettings() { togglePopover(settings: true) }
    @objc private func pause() { model.pause() }
    @objc private func resume() { model.resume() }

    // MARK: - Development

    /// `STRAYLIGHT_SNAPSHOT=<file.png>` writes every rendered menu bar image to
    /// that file, for checking rendering without a screen capture.
    private static let snapshotPath = ProcessInfo.processInfo.environment["STRAYLIGHT_SNAPSHOT"]

    /// `STRAYLIGHT_POPOVER_SNAPSHOT=<file.png>` renders the popover's view
    /// after `STRAYLIGHT_POPOVER_DELAY` seconds (default 15, past warm-up) and
    /// writes it to that file. `STRAYLIGHT_POPOVER_PAGE=settings|first-run|paused`
    /// picks what it shows; `paused` pauses first. `wifi` shows the Wi‑Fi card
    /// from the default Wi‑Fi interface even when traffic goes elsewhere.
    /// `STRAYLIGHT_POPOVER_RANGE=hour|day|week` sets the chart's range.
    /// `STRAYLIGHT_DIAGNOSTICS=<file>` also writes Copy diagnostics' text there. It's drawn in an off-screen window, since a real
    /// popover closes at once when the app doesn't get focus.
    private static let popoverSnapshotPath = ProcessInfo.processInfo.environment["STRAYLIGHT_POPOVER_SNAPSHOT"]
    private var snapshotWindow: NSWindow?

    private func schedulePopoverSnapshot(to path: String) {
        let environment = ProcessInfo.processInfo.environment
        let delay = environment["STRAYLIGHT_POPOVER_DELAY"].flatMap(Double.init) ?? 15
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            if environment["STRAYLIGHT_POPOVER_PAGE"] == "paused" { model.pause() }
            if environment["STRAYLIGHT_POPOVER_PAGE"] == "wifi", let name = CWWiFiClient.shared().interface()?.interfaceName {
                model.showWiFi(interface: name)
            }
            if let file = environment["STRAYLIGHT_DIAGNOSTICS"] {
                Task { try? await Diagnostics.text(model: model, preferences: preferences).write(toFile: file, atomically: true, encoding: .utf8) }
            }
            let state = PopoverState()
            state.showingSettings = environment["STRAYLIGHT_POPOVER_PAGE"] == "settings"
            state.showingFirstRun = environment["STRAYLIGHT_POPOVER_PAGE"] == "first-run"
            if let range = environment["STRAYLIGHT_POPOVER_RANGE"].flatMap(ChartRange.init) { state.chartRange = range }
            let actions = PopoverActions(export: { _, _ in }, copyDiagnostics: {}, dismissFirstRun: {})
            let view = NSHostingView(rootView: PopoverView(model: model, preferences: preferences, state: state, actions: actions))
            let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 340, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            window.orderFrontRegardless()
            snapshotWindow = window
            model.detailsVisible = true
            // Let history load and the layout settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                window.setContentSize(view.fittingSize)
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let image = bitmap.cgImage { Self.writeSnapshot(image, to: path) }
                }
                window.orderOut(nil)
                snapshotWindow = nil
                model.detailsVisible = popover?.isShown == true
            }
        }
    }

    private static func writeSnapshot(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
