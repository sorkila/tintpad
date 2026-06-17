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
        guard AppEnvironment.isBundled else {
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
