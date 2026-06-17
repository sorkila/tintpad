import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "launch at login" toggle.
/// Requires a proper signed app bundle to take effect; from a bare `swift run`
/// binary the registration may no-op, which is fine for the spike.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Tintpad: launch-at-login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}
