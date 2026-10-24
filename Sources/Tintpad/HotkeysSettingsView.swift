import KeyboardShortcuts
import SwiftUI

/// Every key Tintpad answers to: the two global shortcuts, recorded with the
/// KeyboardShortcuts `Recorder` (which reports clashes itself), and the
/// drop's own keys from `PaletteKeys.all`, the list a test pins to the
/// README, so this pane cannot drift from it.
struct HotkeysSettingsView: View {
    var body: some View {
        Form {
            Section {
                HotkeyRow(
                    title: "Summon Tintpad",
                    caption: "Open the drop from anywhere.",
                    name: .summon
                )
                HotkeyRow(
                    title: "Continue last session",
                    caption: "Pick up your most recent conversation in its repo.",
                    name: .continueLast
                )
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Pick a chord no other app uses.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                // Keys are machine values, the one place mono belongs here.
                // A Grid, so the key column sizes to its widest key at any
                // Dynamic Type size.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                    ForEach(PaletteKeys.all) { row in
                        GridRow {
                            Text(row.keys).font(.monoStyle(.callout))
                            Text(row.action).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("In the drop")
            } footer: {
                Text("Hold ⌘ in the drop to see each repo's number and each chip's key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct HotkeyRow: View {
    let title: String
    let caption: String
    let name: KeyboardShortcuts.Name

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
        .padding(.vertical, 6)
    }
}
