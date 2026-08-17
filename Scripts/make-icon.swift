#!/usr/bin/env swift
// Builds the app icon family from the shipped artwork — the drop, rendered
// once (Resources/appicon-source.png, 1024x1024, transparent corners), never
// re-drawn in code. Rerun after replacing the source art.
//
//   swift Scripts/make-icon.swift
//
// Writes Resources/Tintpad.icns, docs/assets/icon.png (512), and the web
// favicon family (icon 64, apple-touch-icon 180, favicon-16).

import AppKit

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let source = root.appendingPathComponent("Resources/appicon-source.png")

guard let art = NSImage(contentsOf: source) else {
    fputs("no artwork at \(source.path)\n", stderr); exit(1)
}

func write(_ image: NSImage, px: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// The iconset, then icns via iconutil.
let work = fm.temporaryDirectory.appendingPathComponent("Tintpad.iconset")
try? fm.removeItem(at: work)
try! fm.createDirectory(at: work, withIntermediateDirectories: true)
for s in [16, 32, 128, 256, 512] {
    write(art, px: s, to: work.appendingPathComponent("icon_\(s)x\(s).png"))
    write(art, px: s * 2, to: work.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
}
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", work.path, "-o",
                  root.appendingPathComponent("Resources/Tintpad.icns").path]
task.launch(); task.waitUntilExit()

// Docs + web family.
write(art, px: 512, to: root.appendingPathComponent("docs/assets/icon.png"))
write(art, px: 64, to: root.appendingPathComponent("web/assets/icon.png"))
write(art, px: 180, to: root.appendingPathComponent("web/assets/apple-touch-icon.png"))
write(art, px: 16, to: root.appendingPathComponent("web/assets/favicon-16.png"))
write(art, px: 32, to: root.appendingPathComponent("web/assets/favicon-32.png"))
print("done: icns + docs/assets/icon.png + web favicon family")
