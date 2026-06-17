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
            AppearanceSettingsView(store: store)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            AboutSettingsView()
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
        return Button {
            store.settings.tintAccent = tint
            store.save()
        } label: {
            Circle()
                .fill(tint.color)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.9 : 0), lineWidth: 2)
                    .padding(-3))
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(selected ? 0.8 : 0)))
        }
        .buttonStyle(.plain)
        .help(tint.displayName)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "command")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(.tint)
            Text("Tintpad").font(.title.bold())
            Text("Phase 1 (MVP) — local-only, no accounts.")
                .font(.callout).foregroundStyle(.secondary)
            Divider().padding(.horizontal, 80)
            VStack(spacing: 6) {
                LabeledContent("Version", value: "0.1.0-dev")
                LabeledContent("Data", value: "~/Library/Application Support/Tintpad")
            }
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Check for Updates…") {}.disabled(true)
                Link("tintpad.com", destination: URL(string: "https://tintpad.com")!)
            }
            .padding(.top, 4)
            Text("Update channel (Sparkle) and license unlock land in Phase 2.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
