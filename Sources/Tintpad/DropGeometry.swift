import CoreGraphics

/// The numbers the drop lays out with, resolved once per summon from the
/// summon screen's `NotchGeometry` and the Dynamic Type scale.
///
/// Pure on purpose: every size the capsule, its chips and its window take
/// lives here, so the view holds no geometry literals and the rules are
/// tested rather than eyeballed.
///
/// - Notched: the capsule is as tall as the housing is deep (clamped to
///   32...40), hangs `gap` below the housing's lower edge, and is never
///   narrower than the housing plus one capsule height either side.
/// - Floating pill (no notch): 36pt tall, `gap` below the menu bar, 280pt
///   minimum.
///
/// Nothing renders behind the camera: the window's top `restHeight` points
/// are transparent headroom and the capsule starts `gap` below them.
struct DropGeometry: Equatable {
    /// Air between the housing (or the menu bar) and the capsule.
    static let gap: CGFloat = 8
    /// The bead the drop forms from before it spreads.
    static let beadSize: CGFloat = 12
    /// Transparent room around the capsule for its contact shadow (radius 8,
    /// y 2), so the blur never clips into a seam at the window edge.
    static let shadowMargin: CGFloat = 20
    /// Chips sit this far inside the capsule, top and bottom.
    static let chipInset: CGFloat = 6
    /// The pill's height before Dynamic Type, and its minimum width.
    static let pillHeight: CGFloat = 36
    static let pillMinWidth: CGFloat = 280
    /// Housing depths outside this range are clamped (a 37pt housing is a
    /// 37pt capsule, a hypothetical 24pt one still gets a usable 32).
    static let housingHeightRange: ClosedRange<CGFloat> = 32...40

    let dropHeight: CGFloat
    let chipHeight: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    /// Air between the capsule's edge and a chip (horizontal padding equals
    /// the vertical inset, the optical law).
    var chipInsetResolved: CGFloat { (dropHeight - chipHeight) / 2 }

    static func resolve(_ notch: NotchGeometry, typeScale: CGFloat) -> DropGeometry {
        let base = notch.hasNotch
            ? min(max(notch.restHeight, housingHeightRange.lowerBound), housingHeightRange.upperBound)
            : pillHeight
        let dropHeight = base * typeScale
        let minWidth = notch.hasNotch ? notch.housingWidth + 2 * dropHeight : pillMinWidth
        return DropGeometry(
            dropHeight: dropHeight,
            chipHeight: dropHeight - 2 * chipInset,
            // A very narrow screen must not invert the range.
            minWidth: min(minWidth, notch.maxWidth),
            maxWidth: notch.maxWidth)
    }

    /// The capsule's hugged width: the natural content width clamped to the
    /// range, then rounded up to the next multiple of 8 (and re-capped at
    /// `max`), so typing a character doesn't nudge the capsule a point.
    static func hugWidth(natural: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        let clamped = Swift.min(Swift.max(natural, lower), upper)
        return Swift.min((clamped / 8).rounded(.up) * 8, upper)
    }

    /// The width rule while the field holds text: the capsule may grow but
    /// never shrink, so a narrowing filter doesn't pull the drop in under
    /// the caret on every keystroke. An empty field re-hugs, so deleting
    /// back to nothing (or leaving a capture mode) settles to the content.
    static func ratchet(previous: CGFloat, proposed: CGFloat, queryEmpty: Bool) -> CGFloat {
        queryEmpty ? proposed : Swift.max(previous, proposed)
    }

    /// The window's height: housing depth + gap + capsule + shadow room.
    static func windowHeight(_ notch: NotchGeometry, drop: DropGeometry) -> CGFloat {
        notch.restHeight + gap + drop.dropHeight + shadowMargin
    }

    /// The window's width, fixed per summon: the capsule hugs inside it, so
    /// the window never resizes while typing.
    static func windowWidth(_ notch: NotchGeometry) -> CGFloat {
        notch.maxWidth + 2 * shadowMargin
    }
}
