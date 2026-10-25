import AppKit

/// The status item's glyph and whether it is in the menu bar at all.
enum MenuBarIcon {
    /// The app icon as a template glyph: the glass capsule (outlined, its lit
    /// core solid) above the pad. The menu bar tints it like every native
    /// status item, so it never reads as a sticker next to the system's icons.
    static let plain = make(pendingUpdate: false)
    /// The glyph with a small dot, while an update waits in the menu. Still a
    /// template, the product's one signal stays monochrome.
    static let pendingUpdate = make(pendingUpdate: true)

    /// Hidden means hidden, except while an update waits: the dot on the icon
    /// is where a scheduled update says so (see `UpdaterController`), so the
    /// icon comes back for it and leaves again once the update is gone.
    static func isShown(setting: Bool, pendingUpdate: Bool) -> Bool {
        setting || pendingUpdate
    }

    /// Drawn on a 20×16 canvas in both states, so the dot appearing never
    /// shifts the item, and the capsule stops short of the dot's corner.
    private static func make(pendingUpdate: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { rect in
            NSColor.black.set()
            let line: CGFloat = 1.25
            let capsule = NSRect(x: (rect.width - 11) / 2, y: 9.5, width: 11, height: 6.5)
                .insetBy(dx: line / 2, dy: line / 2)
            let rim = NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2)
            rim.lineWidth = line
            rim.stroke()
            let core = capsule.insetBy(dx: 2.4, dy: 2)
            NSBezierPath(roundedRect: core, xRadius: core.height / 2, yRadius: core.height / 2).fill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 0, width: 16, height: 8), xRadius: 3.5, yRadius: 3.5).fill()
            if pendingUpdate {
                // A clear ring around the dot keeps it apart from the capsule.
                let dot = NSRect(x: rect.maxX - 4, y: rect.maxY - 4, width: 4, height: 4)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
