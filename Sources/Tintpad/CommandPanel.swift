import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted whenever the command panel is shown, so the SwiftUI palette can
    /// reset transient state and refocus the search field.
    static let tintpadPanelDidShow = Notification.Name("tintpadPanelDidShow")
    /// Posted to request the palette be summoned (e.g. right after onboarding).
    static let tintpadSummonPalette = Notification.Name("tintpadSummonPalette")
}

/// The floating command palette window.
///
/// Why a custom `NSPanel` and not a SwiftUI `WindowGroup`: we need a window that
/// can become key to receive typing **without activating the app** (so focus
/// returns to the previous app on close) and that floats above full-screen
/// spaces. SwiftUI's window scenes can't express `.nonactivatingPanel`.
final class CommandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = false      // we DO want key for typing
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true   // native window shadow follows the rounded glass content
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
    }

    // A borderless/nonactivating panel must opt in to becoming key.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc closes.
    override func cancelOperation(_ sender: Any?) {
        controller?.hide()
    }

    weak var controller: CommandPanelController?

    /// Close when focus is lost (clicked elsewhere) — unless we're intentionally
    /// transitioning to another of our windows (e.g. Settings).
    override func resignKey() {
        super.resignKey()
        controller?.panelResignedKey()
    }
}

/// Owns the panel's lifecycle: show (centered, key, without app activation) and
/// hide (returning focus to whatever app was frontmost before).
@MainActor
final class CommandPanelController: NSObject {
    private var panel: CommandPanel?
    /// While true, losing key focus won't hide the app (we're opening Settings).
    private var suppressAutoHide = false

    /// Owned here so it's alive + monitoring before the first summon.
    private(set) lazy var model = PaletteModel(
        store: .shared,
        onClose: { [weak self] in self?.hide() },
        onOpenSettings: { [weak self] in self?.openSettings() })

    /// Install the key monitor at launch so the very first summon is responsive.
    func warm() { model.startMonitoring() }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    /// Screenshot harness (`TINTPAD_SHOWCASE=1`): summon the palette at launch
    /// and keep it up when it loses focus, so demo/OG captures and design work
    /// can drive it from a shell. Never true in a normal run.
    static var isShowcase: Bool { ProcessInfo.processInfo.environment["TINTPAD_SHOWCASE"] == "1" }

    func panelResignedKey() {
        guard !suppressAutoHide, !Self.isShowcase else { return }
        hide()
    }

    /// Open the Settings window without the panel's focus-loss handler hiding
    /// the whole app.
    func openSettings() {
        suppressAutoHide = true
        panel?.orderOut(nil)
        SettingsWindowController.shared.show()
        // Re-enable auto-hide after the transition settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.suppressAutoHide = false }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.appearance = AppStore.shared.settings.appearance.nsAppearance  // follow theme
        center(panel)
        // Activate so the search field becomes first responder and accepts
        // typing; focus returns to the prior app via NSApp.hide on close.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Tell the SwiftUI palette to reset + focus the field on every summon.
        NotificationCenter.default.post(name: .tintpadPanelDidShow, object: nil)
        if Self.isShowcase { dumpRect(panel) }
    }

    /// Write the panel's frame in screencapture coordinates (top-left origin)
    /// so a capture script can crop to it exactly. Showcase mode only.
    private func dumpRect(_ panel: NSPanel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let screen = NSScreen.screens.first else { return }
            let f = panel.frame
            let pad: CGFloat = 40   // include the window shadow
            let top = screen.frame.maxY - f.maxY
            let line = "\(Int(f.minX - pad)),\(Int(top - pad)),\(Int(f.width + pad * 2)),\(Int(f.height + pad * 2))"
            try? line.write(toFile: "/tmp/tintpad-panel-rect", atomically: true, encoding: .utf8)
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        // Returning focus: because we never activated, the previously frontmost
        // app remains active. `hide` is the explicit fallback if it ever did.
        NSApp.hide(nil)
    }

    private func makePanel() -> CommandPanel {
        let width = AppStore.shared.settings.panelWidth
        let rect = NSRect(x: 0, y: 0, width: width, height: 320)
        let panel = CommandPanel(contentRect: rect)
        panel.controller = self
        let root = PaletteView(model: model) { [weak self] height in
            self?.resize(toContentHeight: height)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = panel.contentView?.bounds ?? rect
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    /// Grow/shrink the panel to fit its content, pinned at the top edge so the
    /// search field never moves under the cursor while you type.
    ///
    /// The palette reports the height it wants for its *content*.
    ///
    /// This is a `.titled` panel, so AppKit reserves a ~32pt titlebar strip at
    /// the top: the window's frame has always been that much taller than the
    /// glass you actually see, and SwiftUI lays out inside the matching safe
    /// area. Passing a content height straight to `setFrame` therefore hands the
    /// palette 32pt less than it asked for, which clipped the last row. Add the
    /// insets back. (Opting out of the safe area instead — on the hosting view
    /// or with `.ignoresSafeArea()` — either loops AppKit's constraint pass or
    /// hides the prompt line behind the unpainted strip.)
    private func resize(toContentHeight height: CGFloat) {
        guard let panel else { return }
        let insets = panel.contentView?.safeAreaInsets ?? NSEdgeInsetsZero
        let target = height + insets.top + insets.bottom
        guard abs(panel.frame.height - target) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - target   // keep the top edge fixed
        frame.size.height = target
        panel.setFrame(frame, display: true, animate: false)
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { panel.center(); return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.12  // sit slightly above center
        )
        panel.setFrameOrigin(origin)
    }
}
