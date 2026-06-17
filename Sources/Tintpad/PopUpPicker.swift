import AppKit
import SwiftUI

/// A dropdown backed by a native `NSPopUpButton`. SwiftUI's `Picker`/`Menu`
/// triggered AttributeGraph layout cycles when several appeared in the Settings
/// window on this SDK; the AppKit control sidesteps SwiftUI layout entirely.
struct PopUpPicker: NSViewRepresentable {
    /// (id, label) pairs. id "" is fine (e.g. "Auto").
    let options: [(String, String)]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, options: options) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.options = options
        button.removeAllItems()
        button.addItems(withTitles: options.map(\.1))
        if let idx = options.firstIndex(where: { $0.0 == selection }) {
            button.selectItem(at: idx)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>
        var options: [(String, String)]

        init(selection: Binding<String>, options: [(String, String)]) {
            self.selection = selection
            self.options = options
        }

        @objc func changed(_ sender: NSPopUpButton) {
            let i = sender.indexOfSelectedItem
            if options.indices.contains(i) { selection.wrappedValue = options[i].0 }
        }
    }
}
