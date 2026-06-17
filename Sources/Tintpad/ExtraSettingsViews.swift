import SwiftUI

// MARK: - Prompts

struct PromptsSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if !store.isPro {
                ProBanner(feature: .promptLibrary)
            }
            HSplitView {
                list.frame(minWidth: 180, maxWidth: 240)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .disabled(!store.isPro)
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
                        .font(.system(.body, design: .monospaced))
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
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.sessions) { session in
                        row(session); Divider()
                    }
                    if store.sessions.isEmpty {
                        Text("No sessions yet — launch an agent from the palette.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                }
            }
            Divider()
            HStack {
                Text("Quick-resume the most recent with the Resume-last hotkey (Settings → Hotkeys).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { store.clearSessions() }.disabled(store.sessions.isEmpty)
            }
            .padding(16)
        }
    }

    private func row(_ s: Session) -> some View {
        HStack(spacing: 12) {
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
            Button("Resume") { resume(s) }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func resume(_ s: Session) {
        guard let repo = store.repos.first(where: { $0.id == s.repoID }),
              let agent = store.agent(s.agentID),
              let mode = agent.modes.first(where: { $0.id == s.modeID }) else { return }
        try? LaunchService.launchAgent(repo: repo, agent: agent, mode: mode, prompt: s.prompt, store: store)
    }
}

// MARK: - Shared

struct ProBanner: View {
    let feature: ProFeature
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text(feature.blurb)
            Spacer()
            Link("Get Pro", destination: URL(string: "https://tintpad.com/pro")!)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.yellow.opacity(0.12))
    }
}
