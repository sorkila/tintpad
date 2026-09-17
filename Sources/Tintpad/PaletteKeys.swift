import Foundation

/// Every key the palette answers to, in README order, for the menu bar's
/// "Palette keys" menu. The README's Keys table is the source: a test reads
/// it and pins this list to it row for row, so the two cannot drift. The
/// summon hotkey is the one README row left out, it is global and
/// configurable, and the menu already lists it as "Summon palette".
///
/// Each row must name a key `PaletteModel.handle(_:)` really handles.
enum PaletteKeys {
    struct Row: Equatable, Identifiable {
        let keys: String
        let action: String
        var id: String { keys }
    }

    static let all: [Row] = [
        Row(keys: "↑ ↓", action: "Move through your repos"),
        Row(keys: "← →", action: "Move through your repos while the field is empty"),
        Row(keys: "⏎", action: "Launch what the chips say"),
        Row(keys: "⌘0", action: "Resume the last session exactly"),
        Row(keys: "⌘1–⌘9", action: "Jump straight to the nth repo and launch it"),
        Row(keys: "⌘⏎", action: "Open repo in editor"),
        Row(keys: "⌥⏎", action: "Launch the dangerous mode"),
        Row(keys: "⇧⏎", action: "Launch the safest mode"),
        Row(keys: "⌃⏎", action: "Headless dispatch"),
        Row(keys: "⌃W", action: "New worktree"),
        Row(keys: "⇥ / ⇧⇥", action: "Cycle agent / mode"),
        Row(keys: "⌘L · ⌘P", action: "Inline prompt · cycle saved prompt"),
        Row(keys: "⌘R · Esc", action: "Re-scan repos · close"),
        Row(keys: "⌘,", action: "Settings"),
    ]
}
