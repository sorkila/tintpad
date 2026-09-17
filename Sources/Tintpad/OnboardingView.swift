import AppKit
import ApplicationServices
import KeyboardShortcuts
import SwiftUI

/// First-run onboarding: find the repos, pick a terminal and prove the handoff,
/// then set the summon hotkey last, so it is the freshest thing in mind when
/// the window closes.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.appearance = NSAppearance(named: .darkAqua)
            let hosting = NSHostingView(rootView: OnboardingView(
                store: AppStore.shared,
                onDone: { [weak self] in self?.finish() },
                fit: { [weak self] in self?.fit() }))
            w.contentView = hosting
            w.setContentSize(hosting.fittingSize)   // fit the window to the content
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Refits the window to its content, keeping the top edge where it is.
    /// The steps change height after the window exists (the repos line, a
    /// test launch's error), and a window sized once would clip them.
    func fit() {
        guard let w = window, let content = w.contentView else { return }
        // Let SwiftUI apply the state change before measuring.
        DispatchQueue.main.async {
            let size = content.fittingSize
            let old = w.frame
            let frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            guard abs(frame.height - old.height) > 0.5 || abs(frame.width - old.width) > 0.5 else { return }
            w.setFrame(NSRect(x: old.minX, y: old.maxY - frame.height,
                              width: frame.width, height: frame.height), display: true)
        }
    }

    private func finish() {
        AppStore.shared.settings.hasOnboarded = true
        AppStore.shared.save()
        window?.close()
        // Land the user straight in the palette instead of "nothing happened".
        NotificationCenter.default.post(name: .tintpadSummonPalette, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppStore.shared.settings.hasOnboarded = true
        AppStore.shared.save()
        NSApp.setActivationPolicy(.accessory)
    }
}

struct OnboardingView: View {
    @ObservedObject var store: AppStore
    let onDone: () -> Void
    let fit: () -> Void
    /// Scan roots that exist on disk, cached: a root can sit on a slow iCloud
    /// volume, and stat-ing it on every body render is main-thread work.
    @State private var existingRoots: [String] = []
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .summon)?.description
    @State private var terminalSel = ""
    @State private var axTrusted = false
    @State private var testStatus: String?
    @State private var testOK = false
    // Monochrome, like everything the drop introduces: gray at rest, white
    // where the eye should land, and red only when something is wrong.
    private let errorRed = Color(red: 1, green: 0.42, blue: 0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let icon = BrandImages.appIcon {
                        icon.resizable().interpolation(.high)
                    } else {
                        Image(systemName: "command").foregroundStyle(.primary)
                    }
                }
                .frame(width: 60, height: 60)
                Text("Welcome to Tintpad")
                    .font(.monoStyle(.title2, .bold))
                Text("Summon a coding agent into your terminal at the right repo, in under two seconds, without the mouse.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(1, "Where your repos live", reposLine) {
                Button("Add a folder…") { addFolder() }
            }

            step(2, "Choose your terminal", permissionsBlurb) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $terminalSel) {
                        Text("Auto (first detected)").tag("")
                        ForEach(TerminalRegistry.installed, id: \.bundleID) { t in
                            Text(t.displayName).tag(t.bundleID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)
                    .padding(.leading, -8)   // cancel the pop-up's label inset → aligns with the leading line
                    .onChange(of: terminalSel) { _, v in
                        store.settings.preferredTerminalBundleID = v.isEmpty ? nil : v
                        store.save()
                    }
                    HStack(spacing: 10) {
                        Button("Test launch") { testLaunch() }
                        if testOK {
                            Label("Working", systemImage: "checkmark.circle.fill")
                                .font(.callout).foregroundStyle(.green)
                        }
                    }
                    if let s = testStatus, !testOK {
                        Text(s)
                            .font(.caption).foregroundStyle(errorRed)
                            .fixedSize(horizontal: false, vertical: true)
                        permissionsControl
                    }
                }
                .frame(minHeight: 88, alignment: .topLeading)
            }

            step(3, "Set your summon hotkey", "Press it anywhere to open the drop.") {
                KeyboardShortcuts.Recorder(for: .summon) { new in shortcut = new?.description }
            }

            Button(action: onDone) {
                // The product's own signature, full width: the white chip with
                // black ink, the same object the selected repo wears in the drop.
                Text(OnboardingCopy.doneLabel(shortcut: shortcut)).frame(maxWidth: .infinity)
                    .foregroundStyle(.black)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).tint(.white)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 440, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.07, green: 0.07, blue: 0.07))
        .onAppear {
            // Default to Terminal.app — it's the most reliable handoff (one
            // Automation prompt, no Accessibility/relaunch dance).
            if store.settings.preferredTerminalBundleID == nil,
               TerminalRegistry.adapter(forBundleID: "com.apple.Terminal")?.isInstalled == true {
                store.settings.preferredTerminalBundleID = "com.apple.Terminal"
                store.save()
            }
            terminalSel = store.settings.preferredTerminalBundleID ?? ""
            axTrusted = AXIsProcessTrusted()
            // The app's launch scan may still be walking a slow volume, run it
            // again here so the line fills in as repos land (the merge dedupes).
            store.runAutoDiscoveryInBackground()
            refreshRoots()
        }
        .onChange(of: store.repos.count) { _, _ in fit() }
        .onChange(of: store.settings.rootScanFolders) { _, _ in refreshRoots(); fit() }
        .onChange(of: testStatus) { _, _ in fit() }
        // Re-check after the user returns from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AXIsProcessTrusted()
            shortcut = KeyboardShortcuts.getShortcut(for: .summon)?.description
        }
    }

    /// Step 1's status line. `store.repos` is observed, so it updates as the
    /// background scan lands.
    private var reposLine: String {
        OnboardingCopy.reposLine(count: store.repos.count, existingRoots: existingRoots)
    }

    private func refreshRoots() {
        let fm = FileManager.default
        existingRoots = store.settings.rootScanFolders.filter { root in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: (root as NSString).expandingTildeInPath, isDirectory: &isDir)
                && isDir.boolValue
        }
    }

    /// A user action, so the scan runs synchronously and the line answers at once.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.settings.rootScanFolders.contains(url.path) {
            store.settings.rootScanFolders.append(url.path)
        }
        store.save()
        _ = store.runAutoDiscovery()
    }

    /// The actionable part of step 2: grant Accessibility (Ghostty) or open the
    /// Automation pane (AppleScript terminals). CLI terminals need nothing.
    @ViewBuilder private var permissionsControl: some View {
        switch resolvedTerminalID {
        case "com.mitchellh.ghostty":
            if axTrusted {
                Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else {
                Button("Grant Accessibility…") { requestAccessibility() }
            }
        case "com.googlecode.iterm2", "com.apple.Terminal":
            Button("Open Privacy Settings…") { openPrivacy("Privacy_Automation") }
        default:
            EmptyView()
        }
    }

    /// Opens a harmless window in the chosen terminal. This both triggers the
    /// macOS permission prompt (so it's granted here, in-flow) and proves the
    /// whole handoff works before the user leaves onboarding.
    private func testLaunch() {
        let terminal = TerminalRegistry.preferred(settings: store.settings)
        do {
            _ = try terminal.launch(TerminalLaunch(
                workingDirectory: NSHomeDirectory(),
                command: "echo 'Tintpad is set up, you can close this window.'"))
            testOK = true
            testStatus = "Working, a terminal window just opened."
        } catch {
            testOK = false
            testStatus = "\(error)"
            axTrusted = AXIsProcessTrusted()
        }
    }

    private func requestAccessibility() {
        // Literal value of kAXTrustedCheckOptionPrompt (that global isn't
        // concurrency-safe under Swift 6). Prompts + adds Tintpad to the list.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The terminal that handoff will actually use (explicit choice, or first detected).
    private var resolvedTerminalID: String {
        terminalSel.isEmpty ? (TerminalRegistry.installed.first?.bundleID ?? "") : terminalSel
    }

    /// Permission copy scoped to the chosen terminal — Accessibility is only ever
    /// mentioned for Ghostty (which has no command-open API), not as a blanket ask.
    private var permissionsBlurb: String {
        switch resolvedTerminalID {
        case "com.mitchellh.ghostty":
            return "Ghostty has no command-open API on macOS, so Tintpad types the command for you. That needs Accessibility, so macOS will ask once on first launch. No other terminal needs it."
        case "com.googlecode.iterm2", "com.apple.Terminal":
            return "Tintpad opens your terminal with AppleScript, so macOS asks for Automation once, on first launch. That's the only prompt."
        case "":
            return "Depending on your terminal, macOS may ask once for Automation (iTerm2/Terminal) or Accessibility (Ghostty). Nothing is asked up front."
        default:
            return "No extra permissions needed, Tintpad launches your terminal directly."
        }
    }

    @ViewBuilder
    private func step<C: View>(_ n: Int, _ title: String, _ subtitle: String,
                               @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Step index in the palette's monospace voice, gray so the titles
            // lead. Two mono digits self-align across steps, so no fixed frame
            // is needed at accessibility sizes (a11y #3/#4).
            Text(String(format: "%02d", n))
                .font(.monoStyle(.body, .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.monoStyle(.headline))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                control()
            }
        }
    }
}
