import AppKit
import SwiftUI

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
        hasShadow = true
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

    /// Close when focus is lost (clicked elsewhere).
    override func resignKey() {
        super.resignKey()
        controller?.hide()
    }
}

/// Owns the panel's lifecycle: show (centered, key, without app activation) and
/// hide (returning focus to whatever app was frontmost before).
@MainActor
final class CommandPanelController: NSObject {
    private var panel: CommandPanel?

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        center(panel)
        // Order front and make key WITHOUT activating the app: typing works,
        // but the app never steals the menu bar / Dock focus.
        panel.makeKeyAndOrderFront(nil)
        // Belt-and-suspenders: ensure the panel can receive key events even
        // though the app is an accessory and not active.
        NSApp.activate(ignoringOtherApps: false)
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
        let rect = NSRect(x: 0, y: 0, width: width, height: 420)
        let panel = CommandPanel(contentRect: rect)
        panel.controller = self
        let root = PaletteView(store: AppStore.shared, onClose: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = panel.contentView?.bounds ?? rect
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
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
