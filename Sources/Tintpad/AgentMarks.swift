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
}

/// Real tool logos, pre-rendered once: downsampled + tinted in AppKit at retina
/// resolution with high interpolation, so SwiftUI just shows a crisp bitmap
/// (live `.resizable` scaling / template tinting both aliased at this size).
enum BrandImages {
    static let claude = tinted("claude", NSColor(srgbRed: 0.851, green: 0.459, blue: 0.337, alpha: 1)) // #D97757
    static let codex  = tinted("codex",  NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1)) // #10A37F

    /// The full-color app icon, for in-app use (onboarding, About).
    static let appIcon: Image? = {
        guard let url = Bundle.module.url(forResource: "appicon", withExtension: "png"),
              let ns = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: ns)
    }()

    private static func tinted(_ name: String, _ color: NSColor) -> Image? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        let pts: CGFloat = 18, scale: CGFloat = 3
        let px = Int(pts * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pts, height: pts)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let r = NSRect(x: 0, y: 0, width: pts, height: pts)
        src.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        r.fill(using: .sourceAtop)   // tint only where the glyph is
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: pts, height: pts))
        out.addRepresentation(rep)
        return Image(nsImage: out)
    }
}

/// The agent icon: a faint brand-tinted tile with the brand logo glyph. The
/// glyph is tinted via `.colorMultiply` (not template) so high interpolation is
/// honored and the edges stay crisp.
struct AgentBrandIcon: View {
    let agent: Agent?
    let tint: Color
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(selected ? 0.20 : 0.12))
            .frame(width: 28, height: 28)
            .overlay { glyph }
    }

    @ViewBuilder private var glyph: some View {
        switch AgentBrand.detect(agent) {
        case .claude: logo(BrandImages.claude, fallback: "sparkle")
        case .codex:  logo(BrandImages.codex, fallback: "chevron.left.forwardslash.chevron.right")
        case .generic:
            Image(systemName: agent?.symbol ?? "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint.opacity(selected ? 1 : 0.85))
        }
    }

    @ViewBuilder private func logo(_ image: Image?, fallback: String) -> some View {
        if let image {
            // Already tinted + downsampled at retina res; show 1:1.
            image
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .opacity(selected ? 1 : 0.85)
        } else {
            Image(systemName: fallback)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint.opacity(selected ? 1 : 0.85))
        }
    }
}
