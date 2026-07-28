import SwiftUI

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
    static let paneTitle = Font.system(.title3, design: .monospaced).weight(.semibold)
    static let paneSubtitle = Font.caption
    static let sidebarLabel = Font.system(.callout, design: .monospaced)
    static let mono = Font.system(.callout, design: .monospaced)
    /// Uppercase tracked section label in the palette's monospace voice — the
    /// thread that ties the resizable surfaces to the HUD.
    static let sectionLabelMono = Font.system(.caption2, design: .monospaced).weight(.semibold)
}
