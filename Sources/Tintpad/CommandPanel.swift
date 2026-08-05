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
        // Borderless on purpose: a `.titled` panel reserves a ~32pt titlebar
        // strip, and on macOS 26 the system draws Liquid Glass window chrome
        // into it — a square-cornered ghost band behind our rounded glass.
        // Borderless removes the strip (and its safe-area inset) at the source.
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Status-bar level: the island fuses with the camera housing, which
        // means drawing over the menu bar's strip — .floating sits below it.
        level = .statusBar
        becomesKeyOnlyIfNeeded = false      // we DO want key for typing
        hidesOnDeactivate = false
        isMovableByWindowBackground = false // the bar is chrome, not a window
        backgroundColor = .clear
        isOpaque = false
        // No system shadow: AppKit would shadow the whole window rect, which
        // includes the transparent margin below the bar. The bar draws its own
        // SwiftUI shadow into that margin instead.
        hasShadow = false
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

    /// Per-summon notch geometry, bridged into the SwiftUI island.
    private let anchor = NotchAnchor()

    /// Install the key monitor at launch so the very first summon is responsive.
    func warm() { model.startMonitoring() }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    /// Screenshot harness (`TINTPAD_SHOWCASE=1`): summon the palette at launch
    /// and keep it up when it loses focus, so demo/OG captures and design work
    /// can drive it from a shell. Never true in a normal run.
    static var isShowcase: Bool { ProcessInfo.processInfo.environment["TINTPAD_SHOWCASE"] == "1" }
    /// The self-driving demo (`TINTPAD_DEMO=1`) shares the showcase's
    /// keep-alive and rect dump, but the summon is driven by AppDelegate.
    static var isDemo: Bool { ProcessInfo.processInfo.environment["TINTPAD_DEMO"] == "1" }

    func panelResignedKey() {
        guard !suppressAutoHide, !Self.isShowcase, !Self.isDemo else { return }
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
        // The island is a black world in every theme — it matches the camera
        // housing, not the appearance setting. Dark fixes AppKit's field
        // editor + focus ring colors to match.
        panel.appearance = NSAppearance(named: .darkAqua)
        dock(panel)
        // Activate so the search field becomes first responder and accepts
        // typing; focus returns to the prior app via NSApp.hide on close.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Tell the SwiftUI palette to reset + focus the field on every summon.
        NotificationCenter.default.post(name: .tintpadPanelDidShow, object: nil)
        if Self.isShowcase || Self.isDemo { dumpRect(panel) }
    }

    /// Write the panel's frame in screencapture coordinates (top-left origin)
    /// so a capture script can crop to it exactly. Showcase mode only. The
    /// bar spans the screen and its shadow lives inside the window, so the
    /// crop needs headroom only for the menu bar above it.
    private func dumpRect(_ panel: NSPanel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let screen = NSScreen.screens.first else { return }
            let f = panel.frame
            let top = screen.frame.maxY - f.maxY
            let pad: CGFloat = 30   // include the menu bar + a little desktop below
            let line = "\(Int(f.minX)),\(Int(top - pad)),\(Int(f.width)),\(Int(f.height + pad * 2))"
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
        // The island's window is sized by `dock` on every show (the summon
        // screen can change), so this rect is a placeholder.
        let rect = NSRect(x: 0, y: 0, width: 800, height: 72)
        let panel = CommandPanel(contentRect: rect)
        panel.controller = self
        let root = PaletteView(model: model, anchor: anchor) { [weak self] height in
            self?.resize(toContentHeight: height)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.frame = panel.contentView?.bounds ?? rect
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    /// The bar reports its window height (bar + shadow room), which changes
    /// only with Dynamic Type. The top edge stays glued under the menu bar —
    /// height grows into the transparent margin below.
    ///
    /// The panel is borderless, so the content view's safe-area insets are
    /// zero — but we still read the real insets rather than assuming, so a
    /// future style-mask change can't silently clip the bar (the `.titled`
    /// era reserved a ~32pt titlebar strip that had to be added back here).
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

    /// Dock the island at the summon screen's top center and feed the view
    /// its notch geometry. On a notched screen the window's top edge sits at
    /// the very top of the screen (over the menu bar strip), so the black
    /// island fuses with the camera housing; the width of the housing is the
    /// gap between the two auxiliary menu-bar areas. Plain displays get the
    /// floating pill just below the menu bar instead.
    private func dock(_ panel: NSPanel) {
        // Harness pin: screenshot/demo runs must land on the primary display
        // regardless of where the user's focus is, or the capture (which reads
        // the primary) and the panel end up on different screens.
        let pinned = ProcessInfo.processInfo.environment["TINTPAD_SCREEN_PRIMARY"] == "1"
            ? NSScreen.screens.first : nil
        guard let screen = pinned ?? NSScreen.main else { return }
        let hasNotch = screen.safeAreaInsets.top > 0
        // Notched: the window is flush with the screen's very top, and the
        // housing's depth becomes transparent headroom — the string begins
        // exactly where the housing ends. Plain displays: flush under the
        // menu bar, the string hangs from its edge instead.
        anchor.geometry = NotchGeometry(
            hasNotch: hasNotch,
            restHeight: hasNotch ? screen.safeAreaInsets.top : 0,
            maxWidth: min(640, screen.frame.width - 160))
        let width = anchor.geometry.maxWidth + PaletteView.shadowMargin * 2
        let height = panel.frame.height
        let top = hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY
        panel.setFrame(
            NSRect(x: screen.frame.midX - width / 2, y: top - height,
                   width: width, height: height),
            display: true)
    }
}
