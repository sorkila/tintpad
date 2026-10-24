import SwiftUI

// MARK: - Prompts

struct PromptsSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 180, maxWidth: 240)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selectedID == nil { selectedID = store.prompts.first?.id } }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(store.prompts) { p in
                    Text(p.title.isEmpty ? "Untitled" : p.title).tag(p.id)
                }
            }
            Divider()
            HStack {
                Button { add() } label: { Image(systemName: "plus") }
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                Spacer()
            }
            .buttonStyle(.borderless).padding(8)
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = selectedID, let binding = promptBinding(id) {
            Form {
                TextField("Title", text: binding.title)
                Section("Prompt text") {
                    TextEditor(text: binding.text)
                        .font(.monoStyle(.body))
                        .frame(minHeight: 160)
                }
            }
            .formStyle(.grouped).padding(20).id(id)
        } else {
            Text("Select or add a prompt.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func add() {
        let p = PromptTemplate(title: "New prompt", text: "")
        store.addPrompt(p); selectedID = p.id
    }

    private func removeSelected() {
        guard let id = selectedID else { return }
        store.removePrompt(id); selectedID = store.prompts.first?.id
    }

    private func promptBinding(_ id: UUID) -> Binding<PromptTemplate>? {
        guard let idx = store.prompts.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { store.prompts[idx] }, set: { store.prompts[idx] = $0; store.save() })
    }
}

// MARK: - Recents

struct RecentsSettingsView: View {
    @ObservedObject var store: AppStore

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        SettingsScroll {
            SettingsCard("Recent sessions", trailing: AnyView(
                Button("Clear") { store.clearSessions() }
                    .controlSize(.small).disabled(store.sessions.isEmpty))) {
                if store.sessions.isEmpty {
                    EmptyStateView(icon: "clock.arrow.circlepath", title: "No sessions yet",
                                   subtitle: "Launch an agent from the palette and it'll show here.")
                } else {
                    ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, session in
                        if i > 0 { Divider() }
                        row(session)
                    }
                }
            }
            Label("Continue the most recent with the Continue last session hotkey (Settings → Keys).",
                  systemImage: "bolt.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ s: Session) -> some View {
        HStack(spacing: 12) {
            AgentBrandIcon(agent: store.agent(s.agentID),
                           tint: store.agent(s.agentID)?.tintHex.flatMap(Color.init(hex:)) ?? .primary,
                           selected: true,
                           monogram: store.monogram(for: store.agent(s.agentID)))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.repoName).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text("\(s.agentName) · \(s.modeName)")
                    if let p = s.prompt, !p.isEmpty {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary)
                    }
                    Text(Self.formatter.string(from: s.date))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Disabled the way the menu item is, with the drop's own reason
            // as the tooltip, so a row never offers a continue that says no.
            let blocker = LaunchService.continueBlocker(for: s, store: store)
            Button("Continue") { continueSession(s) }
                .controlSize(.small)
                .disabled(blocker != nil)
                .help(blocker?.description ?? "Continue this conversation")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Continues the row's conversation the way the hotkey does: through the
    /// drop's gate when it is dangerous, otherwise at once. Beeps when the
    /// session can't be continued or the launch fails, stays quiet on a
    /// double press while it is already opening.
    private func continueSession(_ s: Session) {
        NotificationCenter.default.post(name: .tintpadContinueSession, object: s.id)
    }
}
