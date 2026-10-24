import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI

/// Wraps Sparkle's standard updater. The feed URL and public EdDSA key live in
/// Info.plist (`SUFeedURL`, `SUPublicEDKey`). Updates are only delivered from a
/// signed, notarized build hosting a valid appcast — from a bare `swift run`
/// binary "check for updates" simply reports none.
///
/// Tintpad lives in the background, which Sparkle's stock alert handles
/// badly: a scheduled update opens its alert *behind* every other app, the
/// alert only surfaced when a summon activated Tintpad, and clicking it took
/// key from the drop, whose dismissal hid the app and the alert with it. So a
/// scheduled update found while the user is busy waits quietly in the menu bar
/// (`pendingVersion`, gentle reminders), and any update alert that does show
/// borrows a regular app presence (`AppPresence`) so it is in front and takes
/// clicks.
@MainActor
final class UpdaterController: NSObject, ObservableObject {
    static let shared = UpdaterController()

    /// nil when running outside a bundle (Sparkle requires a bundle).
    private var controller: SPUStandardUpdaterController?

    @Published var canCheckForUpdates = false
    /// A scheduled update waiting for the user, by display version. The menu
    /// offers it, nothing interrupts.
    @Published private(set) var pendingVersion: String?

    private override init() {
        super.init()
        // Only start Sparkle when it's actually configured: a real bundle AND a
        // real SUPublicEDKey (not the scaffold placeholder). Otherwise the
        // updater "fails to start" and nags on every launch. Dev builds stay
        // dormant; once you set a real key + signed build, it activates.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard AppEnvironment.isBundled,
              !key.isEmpty, key != "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY" else { return }
        let c = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        // Every session end reaches `standardUserDriverWillFinishUpdateSession`
        // except one: Install on Quit closes the status window and leaves the
        // session alive, waiting for the quit. So a status window closing is
        // the fallback release. Not an alert closing: the alert closes before
        // Sparkle opens the download's status window, and releasing in that
        // gap would drop the Dock icon the moment the user says Install.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              Self.controllerName(of: window) == "SUStatusController" else { return }
        // A turn later, so the closing window no longer counts as visible.
        DispatchQueue.main.async { self.releaseIfNoAlertShows() }
    }

    private func releaseIfNoAlertShows() {
        // A modal "up to date" or error alert follows some status closes, and
        // the session's end releases after it.
        guard NSApp.modalWindow == nil,
              !NSApp.windows.contains(where: { $0.isVisible && Self.isUpdateWindow($0) }) else { return }
        AppPresence.release(.update)
    }

    /// Sparkle's alert, status and permission windows (`SUUpdateAlert`,
    /// `SUStatusController`, `SUUpdatePermissionPrompt`).
    static func isUpdateWindow(_ window: NSWindow) -> Bool {
        guard let name = controllerName(of: window) else { return false }
        return name.hasPrefix("SU") || name.hasPrefix("SPU")
    }

    private static func controllerName(of window: NSWindow) -> String? {
        window.windowController.map { String(describing: type(of: $0)) }
    }

    /// Also brings a pending update's alert into focus: Sparkle answers a
    /// check made during an open session by showing that session.
    func checkForUpdates() {
        // Sparkle ignores a check while a scheduled one is mid-flight, and a
        // claim made then would never be released.
        guard let controller, controller.updater.canCheckForUpdates else { return }
        AppPresence.claim(.update)
        controller.updater.checkForUpdates()
    }
}

/// What an update says in the menu and in Settings → About. Pure so the copy
/// is tested, and one place so the two surfaces say the same thing.
enum UpdateCopy {
    /// The menu item, verb first like the "Check for Updates…" it stands in for.
    static func menuTitle(pending: String?) -> String {
        pending.map { "Update to \($0)…" } ?? "Check for Updates…"
    }

    /// About's button. The version is already named on the row above it.
    static func buttonTitle(pending: String?) -> String {
        pending.map { "Install \($0)…" } ?? "Check for Updates…"
    }
}

extension UpdaterController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle's alert only when it would come up in focus anyway (just after
    /// launch, or after the Mac sat idle). Otherwise it would open behind the
    /// user's work, so the menu bar holds the update instead.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            AppPresence.claim(.update)
        } else {
            pendingVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
        AppPresence.release(.update)
    }
}
