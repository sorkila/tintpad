import AppKit
import SwiftUI

/// Which brand mark to draw for an agent, detected from its name/command.
enum AgentBrand {
    case claude, codex, generic

    static func detect(_ agent: Agent?) -> AgentBrand {
        guard let agent else { return .generic }
        let s = (agent.name + " " + agent.commandTemplate).lowercased()
        if s.contains("claude") { return .claude }
        if s.contains("codex") || s.contains("openai") { return .codex }
        return .generic
    }

    /// Per-mark optical corrections.
    ///
    /// Icons in a set have to match in *ink*, not in bounding box. Claude's mark
    /// is an airy radial of thin spokes and Codex's is a dense blob, so at the
    /// same box size Claude carries roughly half the weight and visibly recedes
    /// in a column. Claude is drawn slightly larger and held at a higher resting
    /// opacity; Codex is drawn slightly smaller.
    var optical: (fill: CGFloat, restingOpacity: CGFloat) {
        switch self {
        case .claude:  return (1.10, 0.72)
        case .codex:   return (0.88, 0.52)
        case .generic: return (1.00, 0.74)
        }
    }

    fileprivate var asset: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .generic: return nil
        }
    }
}

/// Brand marks, rasterized on demand at the exact pixel size they'll be drawn.
///
/// The previous version pre-rendered once at 18pt@3x and let SwiftUI rescale
/// that bitmap to whatever the row needed, so every mark went through **two**
/// resamples and arrived soft. Rendering straight from the 600pt source to the
/// final pixel count resamples once, and lets the marks follow Dynamic Type
/// instead of being pinned to one size.
@MainActor
enum BrandImages {
    private static var cache: [String: Image] = [:]

    /// The full-color app icon, for in-app use (onboarding, About). Prefers the
    /// app's multi-representation icon (the .icns renders crisply at any size);
    /// the single-rep PNG downscaled looked pixelated.
    static var appIcon: Image? {
        if AppEnvironment.isBundled {
            let ns = NSApplication.shared.applicationIconImage
            if let ns, ns.size.width > 0 { return Image(nsImage: ns) }
        }
        guard let url = Bundle.module.url(forResource: "appicon", withExtension: "png"),
              let ns = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: ns)
    }

    /// A tinted brand mark sized for `pts` at the current display scale.
    /// Returns nil for `.generic`, which has no artwork and falls back to a
    /// monogram.
    static func mark(_ brand: AgentBrand, tint: Color, pts: CGFloat) -> Image? {
        guard let asset = brand.asset else { return nil }
        let ns = NSColor(tint).usingColorSpace(.sRGB) ?? .white
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let px = Int((pts * scale).rounded())
        let key = "\(asset)-\(px)-\(brand.optical.fill)-\(hex(ns))"
        if let hit = cache[key] { return hit }
        guard let img = render(asset, ns, pts: pts, px: px, fill: brand.optical.fill) else { return nil }
        cache[key] = img
        return img
    }

    private static func hex(_ c: NSColor) -> String {
        String(format: "%02X%02X%02X%02X",
               Int(c.redComponent * 255), Int(c.greenComponent * 255),
               Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
    }

    private static func render(_ name: String, _ color: NSColor,
                               pts: CGFloat, px: Int, fill: CGFloat) -> Image? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pts, height: pts)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // `fill` is the optical correction: >1 lets an airy mark overflow the
        // box slightly, <1 pulls a dense one in.
        let inset = pts * (1 - fill) / 2
        let r = NSRect(x: inset, y: inset, width: pts - inset * 2, height: pts - inset * 2)
        src.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(x: 0, y: 0, width: pts, height: pts).fill(using: .sourceAtop)  // tint only the glyph
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: pts, height: pts))
        out.addRepresentation(rep)
        return Image(nsImage: out)
    }
}

// MARK: - Palette mark
struct AgentBrandIcon: View {
    let agent: Agent?
    let tint: Color
    let selected: Bool
    var monogram: String = ""

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(selected ? 0.20 : 0.12))
            .frame(width: 28, height: 28)
            .overlay {
                if let image = BrandImages.mark(AgentBrand.detect(agent), tint: tint, pts: 18) {
                    image.opacity(selected ? 1 : 0.85)
                } else {
                    Text(monogram.isEmpty ? fallbackMonogram : monogram)
                        .font(.mono(12, .semibold))
                        .foregroundStyle(tint.opacity(selected ? 1 : 0.85))
                }
            }
    }

    /// Settings rows don't always know the whole agent set, so they fall back to
    /// the plain first letter rather than a set-aware monogram.
    private var fallbackMonogram: String {
        Monogram.assign([agent?.name ?? "?"]).first ?? "?"
    }
}
