import SwiftUI

struct AgentsSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            agentList
                .frame(minWidth: 170, maxWidth: 220)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selectedID == nil { selectedID = store.agents.first?.id } }
    }

    // MARK: - List

    private var agentList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(store.agents) { agent in
                    Label(agent.name, systemImage: agent.symbol)
                        .tag(agent.id)
                }
            }
            Divider()
            HStack {
                Button { addAgent() } label: { Image(systemName: "plus") }
                    .disabled(!store.allows(.unlimitedAgents))
                    .help(store.allows(.unlimitedAgents) ? "Add agent" : ProFeature.unlimitedAgents.blurb)
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                Spacer()
                if !store.isPro {
                    Text("\(store.agents.count)/\(FreeTier.maxAgents)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let id = selectedID, let binding = agentBinding(id) {
            AgentEditor(agent: binding)
                .id(id)
        } else {
            Text("Select or add an agent.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func addAgent() {
        let def = RunMode.defaultMode()
        let agent = Agent(
            name: "New Agent", commandTemplate: "mycli {mode} {prompt}",
            acceptsPrompt: true, tintHex: nil, symbol: "terminal",
            modes: [RunMode.safe(), def], defaultModeID: def.id
        )
        store.addAgent(agent)
        selectedID = agent.id
    }

    private func removeSelected() {
        guard let id = selectedID else { return }
        store.removeAgent(id)
        selectedID = store.agents.first?.id
    }

    private func agentBinding(_ id: UUID) -> Binding<Agent>? {
        guard let idx = store.agents.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.agents[idx] },
            set: { store.agents[idx] = $0; store.save() }
        )
    }
}

// MARK: - Editor

private struct AgentEditor: View {
    @Binding var agent: Agent

    var body: some View {
        Form {
            Section("Agent") {
                TextField("Name", text: $agent.name)
                TextField("SF Symbol", text: $agent.symbol)
                Toggle("Accepts a starting prompt", isOn: $agent.acceptsPrompt)
            }

            Section {
                TextField("Command template", text: $agent.commandTemplate)
                    .font(.system(.body, design: .monospaced))
                Text(previewCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Command")
            } footer: {
                Text("Variables: {repoPath} {repoName} {branch} {remote} {prompt} {mode} {shell}")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Run modes") {
                ForEach($agent.modes) { $mode in
                    ModeEditor(mode: $mode, isDefault: agent.defaultModeID == mode.id) {
                        agent.defaultModeID = mode.id
                    } onDelete: {
                        agent.modes.removeAll { $0.id == mode.id }
                        if agent.defaultModeID == mode.id { agent.defaultModeID = agent.modes.first?.id }
                    }
                }
                Button { addMode() } label: { Label("Add mode", systemImage: "plus") }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var previewCommand: String {
        let sample = Repo(path: "/Users/you/repos/\(slug)", name: slug)
        return "cd \(slug) && " + CommandTemplate.preview(
            agent.commandTemplate,
            context: .init(
                repo: sample, mode: agent.defaultMode,
                prompt: agent.acceptsPrompt ? "fix the failing test" : nil,
                branch: "main", remote: nil
            )
        )
    }

    private var slug: String {
        agent.name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private func addMode() {
        agent.modes.append(RunMode(name: "Mode", flags: "", isDangerous: false, description: ""))
    }
}

// MARK: - Mode editor

private struct ModeEditor: View {
    @Binding var mode: RunMode
    let isDefault: Bool
    let makeDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Name", text: $mode.name).frame(width: 110)
                TextField("flags", text: $mode.flags)
                    .font(.system(.body, design: .monospaced))
                if mode.isDangerous {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(dangerTint)
                }
                Button { onDelete() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            HStack {
                TextField("description", text: $mode.description)
                    .font(.caption)
                Spacer()
                Toggle("Dangerous", isOn: $mode.isDangerous)
                    .toggleStyle(.checkbox)
                Button {
                    makeDefault()
                } label: {
                    Label("Default", systemImage: isDefault ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isDefault ? Color.accentColor : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
