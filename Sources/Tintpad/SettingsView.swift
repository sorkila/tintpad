import SwiftUI

/// The first-class Settings window: a native macOS preferences scene with
/// top tabs. Intentional contrast with the dark utilitarian palette — this is
/// the bright, spacious, standard-controls surface (Raycast-style).
struct SettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            HotkeysSettingsView()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            ReposSettingsView(store: store)
                .tabItem { Label("Repos", systemImage: "folder") }
            AgentsSettingsView(store: store)
                .tabItem { Label("Agents", systemImage: "terminal") }
            PromptsSettingsView(store: store)
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
            RecentsSettingsView(store: store)
                .tabItem { Label("Recents", systemImage: "clock.arrow.circlepath") }
            AppearanceSettingsView(store: store)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            AboutSettingsView(store: store)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var installed = TerminalRegistry.installed

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Tintpad at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
            }

            Section("Terminal") {
                Picker("Open agents in", selection: terminalSelection) {
                    Text("Auto (first detected)").tag(String?.none)
                    ForEach(installed, id: \.bundleID) { t in
                        Text(t.displayName).tag(Optional(t.bundleID))
                    }
                }
                HStack {
                    Text(detectedSummary)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Re-detect") { installed = TerminalRegistry.installed }
                }
            }

            Section("Editor") {
                Picker("Open repos in", selection: store.bind(\.preferredEditorID)) {
                    Text("Auto (first detected)").tag(String?.none)
                    ForEach(EditorRegistry.installed) { e in
                        Text(e.name).tag(Optional(e.id))
                    }
                }
                Text("Used by ⌘↵ in the palette. \(editorSummary)")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Also open editor when launching an agent", isOn: store.bind(\.alsoOpenEditor))
            }

            Section("Worktrees") {
                HStack {
                    Text("Worktree root")
                    Spacer()
                    Text(store.settings.worktreeRoot ?? "Sibling of repo")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseWorktreeRoot() }
                    if store.settings.worktreeRoot != nil {
                        Button("Reset") { store.settings.worktreeRoot = nil; store.save() }
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

    private var terminalSelection: Binding<String?> {
        store.bind(\.preferredTerminalBundleID)
    }

    private var detectedSummary: String {
        let names = installed.map(\.displayName)
        return names.isEmpty ? "No terminals detected" : "Detected: \(names.joined(separator: ", "))"
    }

    private var editorSummary: String {
        let names = EditorRegistry.installed.map(\.name)
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
                Button("Check for Updates…") {}.disabled(true)
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
