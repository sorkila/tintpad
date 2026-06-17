import SwiftUI

/// The first-class Settings window — native macOS sidebar navigation
/// (System Settings style) via NavigationSplitView.
struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selection: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section { rows([.general, .appearance, .hotkeys]) }
                Section("Workspace") { rows([.repos, .agents, .prompts]) }
                Section("Activity") { rows([.recents, .github]) }
                Section { rows([.about]) }
            }
            .navigationSplitViewColumnWidth(min: 196, ideal: 208, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selection.color.gradient)
                        .frame(width: 30, height: 30)
                        .overlay(Image(systemName: selection.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selection.title).font(.system(size: 18, weight: .semibold))
                        Text(selection.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
                Divider()
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 740, idealWidth: 800, minHeight: 540, idealHeight: 600)
    }

    private func rows(_ tabs: [SettingsTab]) -> some View {
        ForEach(tabs) { tab in
            Label {
                Text(tab.title)
            } icon: {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tab.color.gradient)
                    .frame(width: 20, height: 20)
                    .overlay(Image(systemName: tab.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white))
            }
            .tag(tab)
        }
    }

    @ViewBuilder private var detailView: some View {
        switch selection {
        case .general:    GeneralSettingsView(store: store)
        case .hotkeys:    HotkeysSettingsView()
        case .repos:      ReposSettingsView(store: store)
        case .agents:     AgentsSettingsView(store: store)
        case .prompts:    PromptsSettingsView(store: store)
        case .recents:    RecentsSettingsView(store: store)
        case .github:     GitHubSettingsView(store: store)
        case .appearance: AppearanceSettingsView(store: store)
        case .about:      AboutSettingsView(store: store)
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, hotkeys, repos, agents, prompts, recents, github, appearance, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"; case .hotkeys: "Hotkeys"; case .repos: "Repos"
        case .agents: "Agents"; case .prompts: "Prompts"; case .recents: "Recents"
        case .github: "GitHub"; case .appearance: "Appearance"; case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"; case .hotkeys: "keyboard.fill"; case .repos: "folder.fill"
        case .agents: "terminal.fill"; case .prompts: "text.bubble.fill"
        case .recents: "clock.arrow.circlepath"; case .github: "arrow.triangle.branch"
        case .appearance: "paintpalette.fill"; case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray; case .appearance: .pink; case .hotkeys: .blue
        case .repos: .orange; case .agents: .green; case .prompts: .teal
        case .recents: .indigo; case .github: Color(white: 0.25); case .about: .gray
        }
    }

    var subtitle: String {
        switch self {
        case .general:    "Startup, terminal, editor, and safety"
        case .hotkeys:    "Global keyboard shortcuts"
        case .repos:      "Your repositories and scan roots"
        case .agents:     "Agents, command templates, and run modes"
        case .prompts:    "Reusable starting prompts"
        case .recents:    "Recent sessions and quick-resume"
        case .github:     "Import repositories from GitHub"
        case .appearance: "Accent tint, theme, and palette"
        case .about:      "Version, license, and updates"
        }
    }
}

// MARK: - General

/// Mirrors the working Appearance tab's structure (Form/Section + store.bind),
/// but uses AppKit `PopUpPicker` for the dropdowns — two SwiftUI `Picker`s in
/// one Form reliably cycled AttributeGraph and crashed on this SDK.
struct GeneralSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var installed = TerminalRegistry.installed
    @State private var editorsInstalled = EditorRegistry.installed

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Tintpad at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
            }

            Section("Terminal") {
                LabeledContent("Open agents in") {
                    PopUpPicker(options: [("", "Auto (first detected)")] + installed.map { ($0.bundleID, $0.displayName) },
                                selection: terminalSelection)
                        .frame(width: 220)
                }
                HStack {
                    Text(detectedSummary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Re-detect") { installed = TerminalRegistry.installed }
                }
            }

            Section("Editor") {
                LabeledContent("Open repos in") {
                    PopUpPicker(options: [("", "Auto (first detected)")] + editorsInstalled.map { ($0.id, $0.name) },
                                selection: editorSelection)
                        .frame(width: 220)
                }
                Text("Used by ⌘↵ in the palette. \(editorSummary)")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Also open editor when launching an agent", isOn: store.bind(\.alsoOpenEditor))
            }

            Section("Worktrees") {
                LabeledContent("Worktree root") {
                    HStack {
                        Text(store.settings.worktreeRoot ?? "Sibling of repo")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseWorktreeRoot() }
                        if store.settings.worktreeRoot != nil {
                            Button("Reset") { store.settings.worktreeRoot = nil; store.save() }
                        }
                    }
                }
                Text("Where ⌃W creates new worktrees. Default places them next to the repo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Safety") {
                Toggle("Confirm before launching a dangerous (YOLO) mode",
                       isOn: store.bind(\.confirmDangerousModes))
                Text("When on, dangerous modes require a second ⏎ in the palette before launching.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var terminalSelection: Binding<String> {
        Binding(get: { store.settings.preferredTerminalBundleID ?? "" },
                set: { store.settings.preferredTerminalBundleID = $0.isEmpty ? nil : $0; store.save() })
    }

    private var editorSelection: Binding<String> {
        Binding(get: { store.settings.preferredEditorID ?? "" },
                set: { store.settings.preferredEditorID = $0.isEmpty ? nil : $0; store.save() })
    }

    private var detectedSummary: String {
        let names = installed.map(\.displayName)
        return names.isEmpty ? "No terminals detected" : "Detected: \(names.joined(separator: ", "))"
    }

    private var editorSummary: String {
        let names = editorsInstalled.map(\.name)
        return names.isEmpty ? "No editors detected." : "Detected: \(names.joined(separator: ", "))."
    }

    private func chooseWorktreeRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.worktreeRoot = url.path
            store.save()
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            Section("Accent tint") {
                Text("The tint colors selection, agent badges, and mode chips — it's the brand.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ForEach(TintAccent.allCases) { tint in
                        swatch(tint)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Appearance") {
                Picker("Theme", selection: store.bind(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Palette") {
                LabeledContent("Width") {
                    HStack {
                        Slider(value: store.bind(\.panelWidth), in: 480...860, step: 20)
                        Text("\(Int(store.settings.panelWidth))pt")
                            .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }

            Section("Frecency") {
                LabeledContent("Half-life") {
                    HStack {
                        Slider(value: store.bind(\.frecencyHalfLifeDays), in: 3...90, step: 1)
                        Text("\(Int(store.settings.frecencyHalfLifeDays))d")
                            .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Text("How fast a repo's ranking decays. Shorter = recency wins; longer = frequency wins.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func swatch(_ tint: TintAccent) -> some View {
        let selected = store.settings.tintAccent == tint
        // Free tier is locked to the default orange; other tints are Pro.
        let locked = !store.isPro && tint != .orange
        return Button {
            if locked { return }
            store.settings.tintAccent = tint
            store.save()
        } label: {
            Circle()
                .fill(tint.color)
                .frame(width: 30, height: 30)
                .opacity(locked ? 0.4 : 1)
                .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.9 : 0), lineWidth: 2)
                    .padding(-3))
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(selected ? 0.8 : 0)))
                .overlay(Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(locked ? 0.9 : 0)))
        }
        .buttonStyle(.plain)
        .help(locked ? "\(tint.displayName) — Pro" : tint.displayName)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var updater = UpdaterController.shared
    @State private var keyInput = ""
    @State private var feedback: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "command")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(store.settings.tintAccent.color)
            HStack(spacing: 8) {
                Text("Tintpad").font(.title.bold())
                if store.isPro {
                    Text("PRO").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(store.settings.tintAccent.color, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
            Text("Local-only, no accounts.")
                .font(.callout).foregroundStyle(.secondary)

            Divider().padding(.horizontal, 80)

            licenseSection

            Divider().padding(.horizontal, 80)

            VStack(spacing: 6) {
                LabeledContent("Version", value: "0.1.0-dev")
                LabeledContent("Data", value: "~/Library/Application Support/Tintpad")
            }
            .font(.system(.callout, design: .monospaced)).frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Link("tintpad.com", destination: URL(string: "https://tintpad.com")!)
            }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var licenseSection: some View {
        if let info = store.licenseInfo {
            VStack(spacing: 6) {
                Label("Pro license active", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(info.email).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Button("Remove license") { store.clearLicense(); keyInput = ""; feedback = nil }
                    .controlSize(.small)
            }
        } else {
            VStack(spacing: 8) {
                Text("Unlock Pro: unlimited agents, YOLO modes, prompt library, per-repo presets, custom tints.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                HStack {
                    TextField("Paste license key", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Button("Activate") {
                        if store.applyLicense(keyInput) {
                            feedback = nil
                        } else {
                            feedback = "Invalid license key."
                        }
                    }
                    .disabled(keyInput.isEmpty)
                }
                .frame(maxWidth: 460)
                if let feedback {
                    Text(feedback).font(.caption).foregroundStyle(.red)
                }
                Link("Buy Pro — tintpad.com", destination: URL(string: "https://tintpad.com/pro")!)
                    .font(.callout)
            }
        }
    }
}
