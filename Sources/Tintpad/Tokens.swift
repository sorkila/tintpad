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
enum TypeRamp {
    static let paneTitle = Font.title3.weight(.semibold)
    static let paneSubtitle = Font.caption
    static let sidebarLabel = Font.callout
    static let sectionLabel = Font.caption.weight(.semibold)
    static let mono = Font.system(.callout, design: .monospaced)
}
