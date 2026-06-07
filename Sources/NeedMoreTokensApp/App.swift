import SwiftUI
import AppKit
import Observation
import NeedMoreTokensKit

@main
struct NeedMoreTokensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI is an AppKit status item + panel (managed by the delegate) so the
        // popover can be resizable, persistent, and stay open until dismissed —
        // none of which a SwiftUI MenuBarExtra supports. This empty Settings scene
        // just satisfies the App protocol's Scene requirement.
        Settings { EmptyView() }
    }
}

/// Owns the menu-bar status item and the popover panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var panel: NMTPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.title = "⋯"
        statusItem = item
        observeStatusTitle()
        model.start()
    }

    @objc private func togglePanel() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            presentPanel()
        }
    }

    private func presentPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Restore the saved frame; if there isn't one, anchor under the status item.
        if panel.setFrameUsingName(Self.frameAutosaveName) == false {
            positionUnderStatusItem(panel)
        }
        clampToScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A saved frame from a now-disconnected display (or a changed resolution) can be
    /// offscreen or oversized; re-anchor and clamp it to the current screen.
    private func clampToScreen(_ panel: NMTPanel) {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = panel.frame
        if !visible.intersects(frame) {
            positionUnderStatusItem(panel)
            frame = panel.frame
        }
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        panel.setFrame(frame, display: false)
    }

    private func makePanel() -> NMTPanel {
        let hosting = NSHostingView(rootView: PopoverView(model: model))
        let panel = NMTPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false          // stay open until explicitly dismissed
        panel.animationBehavior = .utilityWindow
        panel.contentView = hosting
        panel.contentMinSize = NSSize(width: 300, height: 220)
        panel.setFrameAutosaveName(Self.frameAutosaveName)   // persistent size + position
        return panel
    }

    private func positionUnderStatusItem(_ panel: NMTPanel) {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            panel.center(); return
        }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var origin = NSPoint(x: buttonRect.maxX - panel.frame.width, y: buttonRect.minY - panel.frame.height - 6)
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - panel.frame.width - 8))
            origin.y = max(visible.minY + 8, origin.y)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Status item title (live)

    private func observeStatusTitle() {
        withObservationTracking {
            applyStatusTitle()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatusTitle() }
        }
    }

    private func applyStatusTitle() {
        guard let button = statusItem?.button else { return }
        guard let lowest = model.lowestRemainingPercent else {
            button.title = "⋯"
            return
        }
        // Scale the menu-bar number with the same UI-size toggle as the popover, so
        // "make everything bigger" also enlarges the one item that's always on screen.
        let step = UserDefaults.standard.integer(forKey: "uiSizeStep")
        let size = NSFont.systemFontSize(for: .small) + CGFloat(max(0, step)) * 1.5
        button.attributedTitle = NSAttributedString(
            string: "\(Int(lowest.rounded()))%",
            attributes: [
                .foregroundColor: Self.color(forRemaining: lowest),
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            ]
        )
    }

    private static func color(forRemaining remaining: Double) -> NSColor {
        switch remaining {
        case ..<15: .systemRed
        case ..<40: .systemOrange
        default: .labelColor
        }
    }

    private static let frameAutosaveName = "NMTPopoverPanel"
}

/// Floating panel that can become key (so its controls work) and closes on Escape,
/// but does not auto-dismiss when the app loses focus.
final class NMTPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
