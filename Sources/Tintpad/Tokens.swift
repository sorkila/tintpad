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
/// The system-wide voice rule, rewritten for the drop: **SF Pro speaks the
/// product — mono speaks only machine values** (paths, flags, keys). The
/// drop is all SF Pro; Settings and onboarding match it, so chrome and
/// palette are one voice. `Font.mono` survives for content that IS code.
enum TypeRamp {
    static let paneTitle = Font.title3.weight(.semibold)
    static let paneSubtitle = Font.caption
    static let sidebarLabel = Font.callout
    static let mono = Font.monoStyle(.callout)
    /// Uppercase tracked section label — the chip eyebrow's big sibling.
    static let sectionLabelMono = Font.caption2.weight(.semibold)
}
