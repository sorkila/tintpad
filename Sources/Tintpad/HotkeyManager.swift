import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The primary "summon Tintpad" shortcut.
    static let summon = Self("summon")
    /// Continue the most recent session's conversation (no palette unless
    /// the gate needs one). Stored under its old name, so a chord recorded
    /// before the rename keeps working.
    static let continueLast = Self("resumeLast")
}

/// Registers the global summon hotkey. ⌥⌘Space is seeded when nothing is set,
/// before onboarding shows, so the hotkey works from the first launch and
/// onboarding's last step (and its Done button) can name it. The Recorder
/// there, or in Settings → Keys, replaces it.
enum HotkeyManager {
    static func configureSpikeDefaultIfNeeded() {
        if KeyboardShortcuts.getShortcut(for: .summon) == nil {
            KeyboardShortcuts.setShortcut(.init(.space, modifiers: [.option, .command]), for: .summon)
        }
    }

    static func onSummon(_ handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .summon, action: handler)
    }

    static func onContinueLast(_ handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .continueLast, action: handler)
    }
}
