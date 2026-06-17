import AppKit
import SwiftUI

/// A translucent "liquid glass" backing using AppKit's vibrancy. `behindWindow`
/// blending blurs whatever is behind the (non-opaque) panel, giving the frosted
/// macOS material look that flat fills can't.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
