#!/usr/bin/env swift
// Renders the app icon from the product's own grammar: a dark tile, the brand
// caret, a block cursor. Deterministic — rerun any time, no design files.
//
//   swift Scripts/make-icon.swift
//
// Writes Resources/Tintpad.icns, Resources/appicon-source.png, and
// docs/assets/icon.png. Requires macOS (AppKit) and `iconutil`.

import AppKit

let accent = NSColor(srgbRed: 1.0, green: 0.45, blue: 0.20, alpha: 1)
let paper = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)

func renderBase(_ px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    defer { img.unlockFocus() }

    // The tile: macOS-style rounded square with breathing room to the canvas.
    let inset = px * 0.065
    let rect = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let corner = rect.width * 0.225
    let tile = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.115, green: 0.115, blue: 0.135, alpha: 1),
        NSColor(srgbRed: 0.055, green: 0.055, blue: 0.07, alpha: 1),
    ])!
    gradient.draw(in: tile, angle: -90)

    // A hairline of light along the top edge, like the glass pieces carry.
    NSColor.white.withAlphaComponent(0.07).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: px * 0.004, dy: px * 0.004),
                              xRadius: corner, yRadius: corner)
    border.lineWidth = px * 0.008
    border.stroke()

    // ❯ + block cursor, centered as one group: the prompt, waiting.
    let font = NSFont.monospacedSystemFont(ofSize: px * 0.42, weight: .heavy)
    let caret = NSAttributedString(string: "❯", attributes: [
        .font: font, .foregroundColor: accent,
    ])
    let caretSize = caret.size()
    let cursorW = px * 0.075
    let cursorH = px * 0.30
    let gap = px * 0.075
    let groupW = caretSize.width + gap + cursorW
    let x = (px - groupW) / 2
    let midY = px / 2

    caret.draw(at: NSPoint(x: x, y: midY - caretSize.height / 2))
    paper.setFill()
    NSBezierPath(roundedRect: NSRect(x: x + caretSize.width + gap,
                                     y: midY - cursorH / 2,
                                     width: cursorW, height: cursorH),
                 xRadius: px * 0.012, yRadius: px * 0.012).fill()
    return img
}

func writePNG(_ image: NSImage, px: Int, to path: String) {
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
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/Tintpad.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let base = renderBase(1024)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                   ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    writePNG(base, px: px, to: iconset.appendingPathComponent("\(name).png").path)
}
writePNG(base, px: 1024, to: root.appendingPathComponent("Resources/appicon-source.png").path)
writePNG(base, px: 512, to: root.appendingPathComponent("docs/assets/icon.png").path)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o",
                  root.appendingPathComponent("Resources/Tintpad.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✓ icon rendered → Resources/Tintpad.icns" : "iconutil failed")
