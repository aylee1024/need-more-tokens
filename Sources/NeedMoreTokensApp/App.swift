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
    /// Last UI-size step we reacted to, so the defaults observer ignores unrelated changes.
    private var lastUISizeStep = UISize.defaultStep

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureUISizeDefaults()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.title = "⋯"
        statusItem = item
        observeStatusTitle()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(uiSizeDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        model.start()
    }

    /// Register the default UI-size step and clamp any out-of-range stored value. We do
    /// NOT reset an existing step: the user's stored value is honored (a saved window
    /// frame already matches it), and the A−/A+ toggle is the size control from here on.
    private func configureUISizeDefaults() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [UISize.defaultsKey: UISize.defaultStep])
        let clamped = UISize.clampedStep(defaults.integer(forKey: UISize.defaultsKey))
        defaults.set(clamped, forKey: UISize.defaultsKey)
        lastUISizeStep = clamped
    }

    private func currentStep() -> Int {
        UISize.clampedStep(UserDefaults.standard.integer(forKey: UISize.defaultsKey))
    }

    /// The popover's A−/A+ buttons write `uiSizeStep` via @AppStorage; mirror that here
    /// so the menu-bar number and the panel size update live, not only on a data refresh.
    /// NotificationCenter delivers on the writer's thread, so hop to the main actor.
    @objc private nonisolated func uiSizeDefaultsChanged() {
        Task { @MainActor [weak self] in self?.handleUISizeDefaultsChanged() }
    }

    private func handleUISizeDefaultsChanged() {
        let step = currentStep()
        guard step != lastUISizeStep else { return }
        lastUISizeStep = step
        applyStatusTitle()
        if let panel, panel.isVisible {
            adjustPanelForStepChange(panel, to: step)
        }
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
        floorPanelSize(panel, step: currentStep())
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
        let step = currentStep()
        let defaultSize = UISize.panelDefaultSize(for: UISize.scale(for: step))
        let hosting = NSHostingView(rootView: PopoverView(model: model))
        let panel = NMTPanel(
            contentRect: NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height),
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
        setPanelMinSize(panel, step: step)
        panel.setFrameAutosaveName(Self.frameAutosaveName)   // persistent size + position
        return panel
    }

    /// The panel's minimum content size for `step` (bigger fonts need more room).
    private func setPanelMinSize(_ panel: NMTPanel, step: Int) {
        let minSize = UISize.panelMinSize(for: UISize.scale(for: step))
        panel.contentMinSize = NSSize(width: minSize.width, height: minSize.height)
    }

    /// On present, keep a restored/anchored frame but never let it be smaller than the
    /// current step needs, so bigger fonts can't be clipped. Manual user size is preserved.
    private func floorPanelSize(_ panel: NMTPanel, step: Int) {
        setPanelMinSize(panel, step: step)
        let minSize = panel.contentMinSize
        let current = panel.contentView?.bounds.size ?? panel.contentLayoutRect.size
        let grown = NSSize(width: max(current.width, minSize.width),
                           height: max(current.height, minSize.height))
        if grown.width > current.width || grown.height > current.height {
            panel.setContentSize(grown)
        }
        clampToScreen(panel)
    }

    /// When the user changes the UI size, adjust the panel intelligently. If the window is
    /// still at some step's natural size (i.e. the user hasn't dragged it — see
    /// `isAppDerivedSize`), snap to the new step's natural size so no step leaves dead space.
    /// If the user has manually resized, preserve that size and only grow it to fit.
    private func adjustPanelForStepChange(_ panel: NMTPanel, to step: Int) {
        setPanelMinSize(panel, step: step)
        let current = panel.contentView?.bounds.size ?? panel.contentLayoutRect.size
        if isAppDerivedSize(current) {
            // Still at some step's natural size (user hasn't dragged it): snap to the new
            // step's natural size so no step leaves dead space.
            let size = UISize.panelDefaultSize(for: UISize.scale(for: step))
            panel.setContentSize(NSSize(width: size.width, height: size.height))
        } else {
            // The user manually resized: preserve it, only grow to fit the bigger step.
            let minSize = panel.contentMinSize
            let grown = NSSize(width: max(current.width, minSize.width),
                               height: max(current.height, minSize.height))
            if grown.width > current.width || grown.height > current.height {
                panel.setContentSize(grown)
            }
        }
        clampToScreen(panel)
    }

    /// True if `size` matches ANY step's natural size within 1pt — i.e. the window came
    /// from the app (a default, a snapped size, or a legacy autosaved frame), not a
    /// deliberate manual drag. Checking every step (not just the previous one) means a
    /// never-dragged user with an old saved frame is still recognized and snaps cleanly.
    private func isAppDerivedSize(_ size: CGSize) -> Bool {
        let tolerance: CGFloat = 1
        return (UISize.minStep...UISize.maxStep).contains { step in
            let natural = UISize.panelDefaultSize(for: UISize.scale(for: step))
            return abs(size.width - natural.width) <= tolerance
                && abs(size.height - natural.height) <= tolerance
        }
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
        // Scale the menu-bar number with the same UI-size toggle as the popover, so
        // "make everything bigger" also enlarges the one item that's always on screen.
        let size = Self.menuBarFontSize(for: currentStep())
        guard let lowest = model.lowestRemainingPercent else {
            button.attributedTitle = Self.statusTitle("⋯", color: .secondaryLabelColor,
                                                      size: size, weight: .medium)
            return
        }
        button.attributedTitle = Self.statusTitle("\(Int(lowest.rounded()))%",
                                                  color: Self.color(forRemaining: lowest),
                                                  size: size, weight: .semibold)
    }

    private static func statusTitle(_ string: String, color: NSColor,
                                    size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
        ])
    }

    /// The menu-bar number scales with the UI-size toggle but is capped so it never
    /// overflows the system menu bar height.
    private static func menuBarFontSize(for step: Int) -> CGFloat {
        let requested = NSFont.systemFontSize(for: .small) * UISize.scale(for: step)
        let cap = max(11, min(16, NSStatusBar.system.thickness - 7))
        return min(requested, cap)
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
