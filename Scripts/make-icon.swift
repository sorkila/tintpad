#!/usr/bin/env swift
// Builds the whole icon family from one Icon Composer export, never re-drawn
// by hand. Export the icon from Icon Composer (iOS, Default, 1024) and save it
// as Resources/appicon-export.png, then:
//
//   swift Scripts/make-icon.swift
//
// Writes Resources/appicon-source.png (the art on Apple's 824-in-1024 macOS
// grid), Resources/Tintpad.icns, Sources/Tintpad/Resources/appicon.png (the
// unbundled `swift run` fallback), docs/assets/icon.png (512), the web family
// (icon 64, apple-touch-icon 180, favicon-16, favicon-32, favicon.ico) and the GitHub
// social card (docs/assets/social-card.png, upload it in the repo settings)
// plus the site's share card (web/assets/og.png, og.jpg).

import AppKit

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
func path(_ p: String) -> URL { root.appendingPathComponent(p) }

guard let export = NSImage(contentsOf: path("Resources/appicon-export.png")) else {
    fputs("no export at Resources/appicon-export.png\n", stderr); exit(1)
}

func render(px: Int, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, to p: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: path(p))
}

// The export is full bleed (iOS). macOS wants the tile at 824 of 1024 with
// transparent margins, or Tahoe's rim lands half off the corners.
let grid = render(px: 1024) { r in
    export.draw(in: r.insetBy(dx: 100, dy: 100))
}
save(grid, to: "Resources/appicon-source.png")
save(grid, to: "Sources/Tintpad/Resources/appicon.png")
let art = NSImage(size: NSSize(width: 1024, height: 1024))
art.addRepresentation(grid)

let work = fm.temporaryDirectory.appendingPathComponent("Tintpad.iconset")
try? fm.removeItem(at: work)
try! fm.createDirectory(at: work, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let rep = render(px: s * scale) { art.draw(in: $0) }
        try! rep.representation(using: .png, properties: [:])!
            .write(to: work.appendingPathComponent("icon_\(s)x\(s)\(suffix).png"))
    }
}
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", work.path, "-o", path("Resources/Tintpad.icns").path]
task.launch(); task.waitUntilExit()

save(render(px: 512) { art.draw(in: $0) }, to: "docs/assets/icon.png")

// The web wants the tile itself, no macOS margins.
save(render(px: 64) { export.draw(in: $0) }, to: "web/assets/icon.png")
// iOS masks the touch icon itself, so it gets an opaque square.
save(render(px: 180) { r in
    NSColor.black.setFill(); r.fill()
    export.draw(in: r)
}, to: "web/assets/apple-touch-icon.png")

// Favicons are redrawn from the icon, not shrunk: at 16px the glass and
// lighting turn to mud. Same composition as the export (dark tile, the pad
// flaring edge to edge across the lower half, the glass capsule's lit ring
// around the white light), flattened to solid fills. A faint rim keeps the
// dark tile from vanishing into a dark tab bar.
func favicon(_ px: Int) -> NSBitmapImageRep {
    render(px: px) { r in
        let n = r.width
        func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> NSRect {
            // Proportions are measured top-down, AppKit draws bottom-up.
            NSRect(x: n * x0, y: n * (1 - y1), width: n * (x1 - x0), height: n * (y1 - y0))
        }
        func fill(_ path: NSBezierPath, _ rgb: (CGFloat, CGFloat, CGFloat)) {
            NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1).setFill()
            path.fill()
        }
        func pill(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ radius: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: rect(x0, y0, x1, y1), xRadius: n * radius, yRadius: n * radius)
        }
        let px1 = 1 / n
        // Colors sampled from the export: graphite tile, navy pad, lit ring, white light.
        let tile = pill(0, 0, 1, 1, 0.23)
        fill(tile, (74, 80, 88))
        let inner = pill(px1, px1, 1 - px1, 1 - px1, 0.23 - px1)
        fill(inner, (30, 32, 35))
        NSGraphicsContext.saveGraphicsState()
        inner.addClip()
        fill(pill(0.02, 0.50, 0.98, 1.4, 0.2), (44, 70, 94))
        NSGraphicsContext.restoreGraphicsState()
        let ring = max(1, n * 0.05) / n
        fill(pill(0.18, 0.13, 0.82, 0.44, 0.155), (150, 156, 164))
        fill(pill(0.18 + ring, 0.13 + ring, 0.82 - ring, 0.44 - ring, 0.155 - ring), (34, 37, 42))
        fill(pill(0.31, 0.22, 0.69, 0.36, 0.07), (255, 255, 255))
    }
}
save(favicon(16), to: "web/assets/favicon-16.png")
save(favicon(32), to: "web/assets/favicon-32.png")

// /favicon.ico for whatever asks the root before reading the page's links:
// an ICO that wraps the 16, 32 and 48 PNGs (Vista-style PNG entries).
do {
    let pngs = [16, 32, 48].map { ($0, favicon($0).representation(using: .png, properties: [:])!) }
    var ico = Data()
    func u16(_ v: Int) { ico.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
    func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16) }
    u16(0); u16(1); u16(pngs.count)
    var offset = 6 + 16 * pngs.count
    for (px, png) in pngs {
        ico.append(contentsOf: [UInt8(px), UInt8(px), 0, 0])
        u16(1); u16(32); u32(png.count); u32(offset)
        offset += png.count
    }
    for (_, png) in pngs { ico.append(png) }
    try! ico.write(to: path("web/favicon.ico"))
}

// GitHub social card, 2x of the 1280x640 GitHub asks for.
let card = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2560, pixelsHigh: 1280,
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                            isPlanar: false, colorSpaceName: .deviceRGB,
                            bytesPerRow: 0, bitsPerPixel: 0)!
card.size = NSSize(width: 2560, height: 1280)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: card)
NSGraphicsContext.current?.imageInterpolation = .high
NSColor(white: 0.035, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 2560, height: 1280).fill()
// Icon and words centered as one group, so the card balances in any crop.
func line(_ s: String, size: CGFloat, weight: NSFont.Weight, white: CGFloat, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(white: white, alpha: 1),
        .kern: kern,
    ])
}
let words = [
    (line("Tintpad", size: 190, weight: .semibold, white: 0.96, kern: -4), CGFloat(660)),
    (line("It falls out of your notch.", size: 76, weight: .regular, white: 0.62), CGFloat(540)),
    (line("FREE  ·  OPEN SOURCE  ·  MACOS", size: 40, weight: .semibold, white: 0.42, kern: 4), CGFloat(420)),
]
let iconSide: CGFloat = 600, gap: CGFloat = 120
let textWidth = words.map { $0.0.size().width }.max()!
let left = (2560 - (iconSide + gap + textWidth)) / 2
export.draw(in: NSRect(x: left, y: 340, width: iconSide, height: iconSide))
for (text, y) in words { text.draw(at: NSPoint(x: left + iconSide + gap, y: y)) }
NSGraphicsContext.restoreGraphicsState()
try! card.representation(using: .png, properties: [:])!.write(to: path("docs/assets/social-card.png"))

// The site's share card is the same card at the 1280x640 Open Graph size, a
// png source and the progressive jpeg the pages actually serve.
let og = NSImage(size: NSSize(width: 2560, height: 1280))
og.addRepresentation(card)
let ogRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 640,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
ogRep.size = NSSize(width: 1280, height: 640)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: ogRep)
NSGraphicsContext.current?.imageInterpolation = .high
og.draw(in: NSRect(x: 0, y: 0, width: 1280, height: 640))
NSGraphicsContext.restoreGraphicsState()
try! ogRep.representation(using: .png, properties: [:])!.write(to: path("web/assets/og.png"))
try! ogRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9, .progressive: true])!
    .write(to: path("web/assets/og.jpg"))

print("done: source, icns, app fallback, docs icon, web family, social + share cards")
