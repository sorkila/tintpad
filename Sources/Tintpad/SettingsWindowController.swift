import AppKit
import SwiftUI

/// Presents Settings in a real `NSWindow`. The SwiftUI `Settings` scene +
/// `showSettingsWindow:` selector is unreliable for accessory/menu-bar apps, so
/// we host `SettingsView` ourselves. Temporarily becomes a regular app while the
/// window is open so it reliably comes to the front, then reverts to accessory.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil { window = makeWindow() }
        window?.appearance = AppStore.shared.settings.appearance == .dark
            ? NSAppearance(named: .darkAqua) : nil
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Tintpad Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: SettingsView(store: AppStore.shared))
        return w
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only accessory app (no Dock icon) when done.
        NSApp.setActivationPolicy(.accessory)
    }
}
