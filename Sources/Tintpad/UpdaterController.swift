import Combine
import Foundation
import Sparkle
import SwiftUI

/// Wraps Sparkle's standard updater. The feed URL and public EdDSA key live in
/// Info.plist (`SUFeedURL`, `SUPublicEDKey`). Updates are only delivered from a
/// signed, notarized build hosting a valid appcast — from a bare `swift run`
/// binary "check for updates" simply reports none.
@MainActor
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    /// nil when running outside a bundle (Sparkle requires a bundle).
    private let controller: SPUStandardUpdaterController?

    @Published var canCheckForUpdates = false

    private init() {
        // Only start Sparkle when it's actually configured: a real bundle AND a
        // real SUPublicEDKey (not the scaffold placeholder). Otherwise the
        // updater "fails to start" and nags on every launch. Dev builds stay
        // dormant; once you set a real key + signed build, it activates.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard AppEnvironment.isBundled,
              !key.isEmpty, key != "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY" else {
            controller = nil
            return
        }
        let c = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
