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

    /// The repo's identity color, tuned per scheme so it reads on glass.
    static func color(for name: String, dark: Bool) -> Color {
        Color(hue: hue(for: name) / 360,
              saturation: dark ? 0.52 : 0.58,
              brightness: dark ? 0.88 : 0.52)
    }

    /// A quieter version for fills, so the letter stays the loudest thing.
    static func fill(for name: String, dark: Bool) -> Color {
        Color(hue: hue(for: name) / 360,
              saturation: dark ? 0.4 : 0.35,
              brightness: dark ? 0.75 : 0.7)
    }
}
