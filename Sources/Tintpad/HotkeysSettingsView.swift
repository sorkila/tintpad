import KeyboardShortcuts
import SwiftUI

/// The hotkey settings centerpiece. Uses the KeyboardShortcuts `Recorder` as
/// the engine, wrapped in a premium-feeling row with a caption.
struct HotkeysSettingsView: View {
    var body: some View {
        Form {
            Section {
                HotkeyRow(
                    title: "Summon Tintpad",
                    caption: "Open the command palette from anywhere.",
                    name: .summon
                )
                HotkeyRow(
                    title: "Resume last session",
                    caption: "Instantly re-launch your most recent repo + agent + mode.",
                    name: .resumeLast
                )
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Set a combo that won't clash with other apps. Conflicts are flagged inline.")
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
