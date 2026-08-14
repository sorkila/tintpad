import SwiftUI

/// The first-class Settings window — native macOS sidebar navigation
/// (System Settings style) via NavigationSplitView.
struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selection: SettingsTab = .general
    // Settings never needs a collapsed sidebar — pin it open and drop the toggle.
    @State private var columns = NavigationSplitViewVisibility.all
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // Stark sidebar: text only, monochrome — selection is weight and
            // ink, matching the drop. Color survives in Settings only where
            // it is content (repo hues, agent tints, danger red).
            List(selection: $selection) {
                Section { rows([.general, .appearance, .hotkeys]) }
                Section { rows([.repos, .agents, .prompts]) } header: { sectionHeader("Workspace") }
                Section { rows([.recents, .github]) } header: { sectionHeader("Activity") }
                Section { rows([.about]) }
            }
            // Solid black, not sidebar material: the wallpaper tinting
            // through translucency put color back into a monochrome room.
            .scrollContentBackground(.hidden)
            .background(Color(white: 0.055))
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                // The sidebar already says where you are — no repeated icon tile.
                VStack(alignment: .leading, spacing: 1) {
                    Text(selection.title).font(TypeRamp.paneTitle)
                    Text(selection.subtitle).font(TypeRamp.paneSubtitle).foregroundStyle(.secondary)
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
        // The tint belongs at the root, not on the sidebar alone. SwiftUI's
        // controls take the accent from the environment without ever naming
        // it: a Toggle's track, a Link's ink, a Label's symbol in a list. So
        // replacing the explicit `Color.accentColor` call sites left the
        // *implicit* ones still painting the user's macOS accent into a black
        // and white room. Tinting the root is the version of this fix that
        // cannot be incomplete, since a control added later inherits it too.
        .tint(.gray)
        // Roomier default: the Agents pane nests a second list inside the detail,
        // so a wider window keeps its editor from getting cramped.
        .frame(minWidth: 820, idealWidth: 920, minHeight: 560, idealHeight: 640)
    }

    private func rows(_ tabs: [SettingsTab]) -> some View {
        // Text only: the labels are short, the groups are labeled, and a
        // glyph next to each word was saying everything twice. Monochrome,
        // like the drop: selection is weight and ink, never color — macOS
        // list selection stays a quiet gray, the label itself carries it.
        ForEach(tabs) { tab in
            Text(tab.title)
                .font(tab == selection ? TypeRamp.sidebarLabel.weight(.semibold)
                                       : TypeRamp.sidebarLabel)
                .foregroundStyle(tab == selection
                    ? AnyShapeStyle(.primary)
                    : AnyShapeStyle(.secondary))
                .tag(tab)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(TypeRamp.sectionLabelMono).tracking(0.6)
            .foregroundStyle(.secondary)
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

    var subtitle: String {
        switch self {
        case .general:    "Startup, terminal, and editor"
        case .hotkeys:    "Global keyboard shortcuts"
        case .repos:      "Your repositories and scan roots"
        case .agents:     "Agents, command templates, and run modes"
        case .prompts:    "Reusable starting prompts"
        case .recents:    "Recent sessions and quick-resume"
        case .github:     "Import repositories from GitHub"
        case .appearance: "Chip tints and ranking"
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
                Toggle("Open in a new tab instead of a window", isOn: store.bind(\.openInNewTab))
                Text("Honored by Ghostty, iTerm2, Terminal, and WezTerm. Other terminals always open a new window.")
                    .font(.caption).foregroundStyle(.secondary)
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

            Section {
                DisclosureGroup("Advanced") {
                    LabeledContent("Worktree root") {
                        HStack {
                            Text(store.settings.worktreeRoot ?? "Sibling of repo")
                                .font(.monoStyle(.caption)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { chooseWorktreeRoot() }
                            if store.settings.worktreeRoot != nil {
                                Button("Reset") { store.settings.worktreeRoot = nil; store.save() }
                            }
                        }
                    }
                    Toggle("Confirm before launching a mode that skips permissions",
                           isOn: store.bind(\.confirmDangerousModes))
                }
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
    // Paired with the callout-based type below so the chip and swatches keep
    // fitting their content at accessibility sizes (a11y #3).
    @ScaledMetric(relativeTo: .callout) private var chipWidth: CGFloat = 48

    var body: some View {
        Form {
            Section("Tint") {
                Toggle("Selected repo's chip in its own hue", isOn: store.bind(\.tintedChips))
                    .disabled(!store.isSupporter)
                Text(store.isSupporter
                     ? "One drop of color in the black: the white chip blooms in the repo's hue. Off keeps the drop pure black and white."
                     : "The Supporter perk. Tip, email your receipt to erik@sorkila.com, get a hand-signed key, and the chip blooms in each repo's own hue.")
                    .font(.caption).foregroundStyle(.secondary)
                    .withInlineLink()
            }

            // No theme picker: the drop, Settings, and onboarding each pin
            // darkAqua on their own window, so Light and System selected
            // nothing a user could see. One black world, no control for it.
            Section {
                DisclosureGroup("Advanced") {
                    slider("Frecency half-life", value: store.bind(\.frecencyHalfLifeDays), range: 3...90, unit: "d", snap: 1)
                    Text("Half-life controls how fast a repo's ranking decays. Shorter = recency wins; longer = frequency wins.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    /// A clean tinted slider (no tick marks) with a value chip; snaps on release.
    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, unit: String, snap: Double) -> some View {
        LabeledContent(title) {
            HStack(spacing: 14) {
                Slider(value: value, in: range) { editing in
                    if !editing { value.wrappedValue = (value.wrappedValue / snap).rounded() * snap }
                }
                .tint(.gray)   // monochrome controls, like the drop
                Text("\(Int((value.wrappedValue / snap).rounded() * snap))\(unit)")
                    .font(TypeRamp.mono.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: chipWidth, alignment: .trailing)
                    .monospacedDigit()
            }
        }
    }

}

// MARK: - About

struct AboutSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var updater = UpdaterController.shared
    @State private var keyInput = ""
    @State private var feedback: String?
    // Display-size mark: no text style is this large, so scale the size itself.
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 14) {
            // The real app icon, not a stand-in glyph — one brand, everywhere.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: markSize, height: markSize)
            HStack(spacing: 8) {
                Text("Tintpad").font(.title.bold())
                if store.isSupporter {
                    Label("Supporter", systemImage: "heart.fill").font(.caption2.bold())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.primary, in: Capsule())
                        .foregroundStyle(.background)
                }
            }
            Text("Free & open source. Local-only, no accounts.")
                .font(.callout).foregroundStyle(.secondary)

            Spacer().frame(height: 8)

            licenseSection

            Spacer().frame(height: 8)

            VStack(spacing: 6) {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
                LabeledContent("Data", value: "~/Library/Application Support/Tintpad")
            }
            .font(.monoStyle(.callout)).frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                // A link earns its affordance from ink and a rule, not from
                // blue: the root tint would otherwise sink these to gray and
                // they would stop reading as clickable at all.
                Link("tintpad.com", destination: URL(string: "https://tintpad.com")!).linkStyle()
                Link("sorkila.com", destination: URL(string: "https://sorkila.com")!).linkStyle()
            }

            Link(destination: URL(string: "https://www.buymeacoffee.com/eriknielsen")!) {
                // The one filled control on the pane: white chip, black ink in
                // dark mode (and the inverse in light) — the drop's chip.
                Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.background)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var licenseSection: some View {
        if let info = store.licenseInfo {
            VStack(spacing: 6) {
                Label("Supporter, thank you ♥", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(info.email).font(.monoStyle(.callout)).foregroundStyle(.secondary)
                Button("Remove key") { store.clearLicense(); keyInput = ""; feedback = nil }
                    .controlSize(.small)
            }
        } else {
            VStack(spacing: 8) {
                Text("Everything's free. If Tintpad saves you time, chip in. Supporters get tinted chips, the selected repo's chip in its own hue: tip, email your receipt to erik@sorkila.com, and I'll send a key to paste below.")
                    .font(.callout).foregroundStyle(.secondary)
                    .withInlineLink()
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                HStack {
                    TextField("Paste supporter key", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.monoStyle(.callout))
                    Button("Activate") {
                        if store.applyLicense(keyInput) {
                            feedback = nil
                        } else {
                            feedback = "That key didn't check out."
                        }
                    }
                    .disabled(keyInput.isEmpty)
                }
                .frame(maxWidth: 460)
                if let feedback {
                    Text(feedback).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}

/// Link styling for the monochrome world.
///
/// Settings tints its root gray so no control borrows the user's macOS accent
/// (see `SettingsView`), but a link that inherits that tint reads as ordinary
/// dimmed text. These give the affordance back the way print always did it,
/// with ink and a rule: full-strength foreground, underlined.
/// `.tint` is not enough here. A `Link` is a button wearing the `.link` button
/// style, and that style paints the system link blue no matter what the tint
/// says, so the plain style has to be asked for before the ink obeys.
extension View {
    func linkStyle() -> some View {
        self.buttonStyle(.plain).foregroundStyle(.primary).underline()
    }
}

/// For prose that carries a bare address SwiftUI turns into a link (the
/// Supporter email). The surrounding caption is secondary, so lifting just the
/// link to primary is what separates it from the sentence around it.
extension Text {
    func withInlineLink() -> some View { self.tint(.primary) }
}
