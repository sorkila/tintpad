import SwiftUI

/// Every repo gets its tint — a stable hue derived from its name, so a tile
/// is recognizable at a glance the way ⌘Tab app icons are. The hue never
/// lands in the danger-red band, which is reserved for "skips permissions".
enum RepoTint {
    /// Degrees in [20, 340): deterministic per name, red band excluded.
    static func hue(for name: String) -> Double {
        var h: UInt32 = 5381
        for b in name.lowercased().utf8 { h = h &* 33 &+ UInt32(b) }
        return 20 + Double(h % 320)
    }

    /// The resting letter: a whisper of the hue, near-monochrome with a
    /// memory of color. The strip reads as one material until you arrive.
    static func color(for name: String, dark: Bool) -> Color {
        Color(hue: hue(for: name) / 360,
              saturation: dark ? 0.28 : 0.32,
              brightness: dark ? 0.88 : 0.48)
    }

    /// The selected letter: the hue in full bloom — arriving at a tile is
    /// the one moment color is spent.
    static func vivid(for name: String, dark: Bool) -> Color {
        Color(hue: hue(for: name) / 360,
              saturation: dark ? 0.6 : 0.62,
              brightness: dark ? 0.96 : 0.55)
    }

    /// A quieter version for the selected tile's fill.
    static func fill(for name: String, dark: Bool) -> Color {
        Color(hue: hue(for: name) / 360,
              saturation: dark ? 0.34 : 0.3,
              brightness: dark ? 0.68 : 0.66)
    }

    /// The tile's short name — more recognizable than a monogram letter.
    /// Whole name when it already fits (≤4 chars), word initials for
    /// multiword names, else a three-letter prefix. Always uppercase.
    static func shortName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "?" }
        if trimmed.count <= 4 { return trimmed.uppercased() }
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        if words.count >= 2 {
            return words.prefix(3).compactMap { $0.first.map(String.init) }
                .joined().uppercased()
        }
        return trimmed.prefix(3).uppercased()
    }
}
