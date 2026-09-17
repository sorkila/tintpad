import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The primary "summon Tintpad" shortcut.
    static let summon = Self("summon")
    /// Instant quick-resume of the most recent session (no palette).
    static let resumeLast = Self("resumeLast")
}

/// Registers the global summon hotkey. ⌥⌘Space is seeded when nothing is set,
/// before onboarding shows, so the hotkey works from the first launch and
/// onboarding's last step (and its Done button) can name it. The Recorder
/// there, or in Settings → Hotkeys, replaces it.
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
