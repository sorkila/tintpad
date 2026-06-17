import Foundation

/// Runtime environment checks.
enum AppEnvironment {
    /// True when running inside a proper `.app` bundle (vs. a bare `swift run`
    /// binary). Several macOS frameworks — UserNotifications, Sparkle — require a
    /// bundle and crash otherwise, so we gate their use on this.
    static let isBundled: Bool = Bundle.main.bundleURL.pathExtension == "app"
}
