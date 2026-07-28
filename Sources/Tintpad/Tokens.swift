import SwiftUI

/// The product's typeface is SF Mono, reached only through `Font.mono` and
/// `Font.monoStyle` — one place defines the voice, so a future face swap is
/// two function bodies (we test-drove IBM Plex Mono and came home).
extension Font {
    /// The one voice at an exact size. Sizes arrive pre-scaled through
    /// `@ScaledMetric`.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The one voice on a Dynamic Type text style (Settings, onboarding).
    static func monoStyle(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}

/// Scalable type ramp for resizable surfaces (honors Dynamic Type).
///
/// The system-wide voice rule: **mono speaks labels and identity, SF Pro
/// speaks prose.** The palette is all-mono (it has no prose); Settings and
/// onboarding use mono for titles, sidebar labels, and section headers, and
/// SF Pro for explanatory text, where reading comfort wins.
enum TypeRamp {
    static let paneTitle = Font.monoStyle(.title3, .semibold)
    static let paneSubtitle = Font.caption
    static let sidebarLabel = Font.monoStyle(.callout)
    static let mono = Font.monoStyle(.callout)
    /// Uppercase tracked section label in the palette's monospace voice — the
    /// thread that ties the resizable surfaces to the HUD.
    static let sectionLabelMono = Font.monoStyle(.caption2, .semibold)
}
