import AppKit

/// Whether Tintpad shows in the Dock and the app switcher. It is an accessory
/// app (`LSUIElement`), and a window the user has to reach (Settings,
/// onboarding, an update alert) borrows a regular presence while it is up, so
/// it comes to the front and can take clicks. These overlap, so each one
/// claims by reason and the app goes back to accessory only when the last one
/// lets go: closing Settings must not pull the Dock icon out from under an
/// update alert that is still waiting for its click.
struct DockPresence: Equatable {
    enum Reason: Hashable { case settings, onboarding, update, storeAlert }

    private(set) var reasons: Set<Reason> = []

    var policy: NSApplication.ActivationPolicy { reasons.isEmpty ? .accessory : .regular }

    mutating func claim(_ reason: Reason) { reasons.insert(reason) }
    mutating func release(_ reason: Reason) { reasons.remove(reason) }
}

/// The app's one `DockPresence`, applied to `NSApp`.
@MainActor
enum AppPresence {
    private static var presence = DockPresence()

    /// Become a regular app (if not already) and come to the front.
    static func claim(_ reason: DockPresence.Reason) {
        presence.claim(reason)
        NSApp.setActivationPolicy(presence.policy)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func release(_ reason: DockPresence.Reason) {
        presence.release(reason)
        NSApp.setActivationPolicy(presence.policy)
    }
}
