import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The primary "summon Tintpad" shortcut.
    static let summon = Self("summon")
    /// Instant quick-resume of the most recent session (no palette).
    static let resumeLast = Self("resumeLast")
}

/// Registers the global summon hotkey. In production we will NOT set a default
/// and will instead prompt the user via the Recorder on first launch (per the
/// brief). For the Phase 0 spike we seed ⌥⌘Space if nothing is set, so the
/// hotkey is testable immediately.
enum HotkeyManager {
    static func configureSpikeDefaultIfNeeded() {
        if KeyboardShortcuts.getShortcut(for: .summon) == nil {
            KeyboardShortcuts.setShortcut(.init(.space, modifiers: [.option, .command]), for: .summon)
        }
    }

    static func onSummon(_ handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .summon, action: handler)
    }

    static func onResumeLast(_ handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .resumeLast, action: handler)
    }
}
