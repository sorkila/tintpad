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
// (icon 64, apple-touch-icon 180, favicon-16, favicon-32) and the GitHub
// social card (docs/assets/social-card.png, upload it in the repo settings).

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

// Favicons are redrawn as the icon's silhouette, not shrunk: at 16px the glass
// and lighting turn to mud, and a dark tile vanishes into a dark tab bar. The
// rim keeps the tile's edge, the white pill is the one thing that must survive.
func favicon(_ px: Int) -> NSBitmapImageRep {
    render(px: px) { r in
        let n = r.width
        func pill(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ radius: CGFloat, _ white: CGFloat) {
            // Proportions are measured top-down, AppKit draws bottom-up.
            let rect = NSRect(x: n * x0, y: n * (1 - y1), width: n * (x1 - x0), height: n * (y1 - y0))
            NSColor(white: white, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: n * radius, yRadius: n * radius).fill()
        }
        let rim = max(1, n * 0.045) / n
        pill(0, 0, 1, 1, 0.24, 0.38)
        pill(rim, rim, 1 - rim, 1 - rim, 0.24 - rim, 0.08)
        pill(0.10, 0.56, 0.90, 0.93, 0.17, 0.25)
        pill(0.20, 0.17, 0.80, 0.48, 0.155, 0.48)
        pill(0.31, 0.25, 0.69, 0.40, 0.075, 1.0)
    }
}
save(favicon(16), to: "web/assets/favicon-16.png")
save(favicon(32), to: "web/assets/favicon-32.png")

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
export.draw(in: NSRect(x: 220, y: 340, width: 600, height: 600))
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, white: CGFloat, y: CGFloat, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(white: white, alpha: 1),
        .kern: kern,
    ]
    NSAttributedString(string: s, attributes: attrs).draw(at: NSPoint(x: 940, y: y))
}
text("Tintpad", size: 190, weight: .semibold, white: 0.96, y: 660, kern: -4)
text("It falls out of your notch.", size: 76, weight: .regular, white: 0.62, y: 540)
text("FREE  ·  OPEN SOURCE  ·  MACOS", size: 40, weight: .semibold, white: 0.42, y: 420, kern: 4)
NSGraphicsContext.restoreGraphicsState()
try! card.representation(using: .png, properties: [:])!.write(to: path("docs/assets/social-card.png"))

print("done: source, icns, app fallback, docs icon, web family, social card")
