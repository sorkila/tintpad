import CoreText
import SwiftUI

/// The product's typeface: IBM Plex Mono (SIL OFL, bundled in Resources/Fonts,
/// license alongside). Registered once at launch, process-scoped. Every call
/// site goes through `Font.mono`/`Font.monoStyle`, which fall back to the
/// system mono if registration ever fails — the app must never render blank.
enum BrandFont {
    nonisolated(unsafe) private(set) static var available = false

    static let regular = "IBMPlexMono"
    static let medium = "IBMPlexMono-Medium"
    static let semibold = "IBMPlexMono-SemiBold"
    static let bold = "IBMPlexMono-Bold"

    static func register() {
        for name in ["IBMPlexMono-Regular", "IBMPlexMono-Medium",
                     "IBMPlexMono-SemiBold", "IBMPlexMono-Bold"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        available = NSFont(name: regular, size: 12) != nil
    }

    static func psName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return bold
        case .semibold: return semibold
        case .medium: return medium
        default: return regular
        }
    }
}

extension Font {
    /// The one voice at an exact size. Sizes arrive pre-scaled through
    /// `@ScaledMetric`, so this uses `fixedSize` — `custom(_:size:)` would
    /// scale with Dynamic Type a second time.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard BrandFont.available else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(BrandFont.psName(for: weight), fixedSize: size)
    }

    /// The one voice on a Dynamic Type text style (Settings, onboarding).
    static func monoStyle(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        guard BrandFont.available else {
            return .system(style, design: .monospaced).weight(weight)
        }
        let base: CGFloat
        switch style {
        case .title2: base = 17
        case .title3: base = 15
        case .headline, .body: base = 13
        case .callout: base = 12
        case .subheadline: base = 11
        default: base = 10   // footnote, caption, caption2
        }
        return .custom(BrandFont.psName(for: weight), size: base, relativeTo: style)
    }
}

/// Design tokens — one source of truth for spacing, radii, and the type ramp.
///
/// Note on Dynamic Type: resizable surfaces (Settings, onboarding) use the
/// scalable `TypeRamp` (text-style based, so they follow the system text size).
/// The command palette is a deliberately fixed-size HUD — like Spotlight — and
/// keeps its own tuned point sizes so its dense layout stays exact.
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 18
    static let xl: CGFloat = 28
}

enum Radius {
    static let tile: CGFloat = 7
    static let row: CGFloat = 10
    static let panel: CGFloat = 18
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
