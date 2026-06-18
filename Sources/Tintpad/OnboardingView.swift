import AppKit
import KeyboardShortcuts
import SwiftUI

/// First-run onboarding: set the summon hotkey, pick a terminal, and explain
/// the permissions Tintpad will ask for.
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
            let hosting = NSHostingView(rootView: OnboardingView { [weak self] in self?.finish() })
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

    private func finish() {
        AppStore.shared.settings.hasOnboarded = true
        AppStore.shared.save()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        AppStore.shared.settings.hasOnboarded = true
        AppStore.shared.save()
        NSApp.setActivationPolicy(.accessory)
    }
}

struct OnboardingView: View {
    let onDone: () -> Void
    @State private var terminalSel = ""
    private let accent = Color(red: 1.0, green: 0.45, blue: 0.20)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let icon = BrandImages.appIcon {
                        icon.resizable().interpolation(.high)
                    } else {
                        Image(systemName: "command").foregroundStyle(accent)
                    }
                }
                .frame(width: 60, height: 60)
                Text("Welcome to Tintpad").font(.title.bold())
                Text("Summon a coding agent into your terminal at the right repo — in under two seconds, without the mouse.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(1, "Set your summon hotkey", "Press it anywhere to open the palette.") {
                KeyboardShortcuts.Recorder(for: .summon)
            }

            step(2, "Choose your terminal", "Where agents launch.") {
                Picker("", selection: $terminalSel) {
                    Text("Auto (first detected)").tag("")
                    ForEach(TerminalRegistry.installed, id: \.bundleID) { t in
                        Text(t.displayName).tag(t.bundleID)
                    }
                }
                .labelsHidden().frame(maxWidth: 220)
                .onChange(of: terminalSel) { _, v in
                    AppStore.shared.settings.preferredTerminalBundleID = v.isEmpty ? nil : v
                    AppStore.shared.save()
                }
            }

            step(3, "Permissions", permissionsBlurb) {
                EmptyView()
            }

            Button(action: onDone) {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).tint(accent)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 440, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.07, green: 0.07, blue: 0.07))
        .onAppear { terminalSel = AppStore.shared.settings.preferredTerminalBundleID ?? "" }
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
            return "Ghostty has no command-open API on macOS, so Tintpad types the command for you. That needs Accessibility — macOS will ask once, on first launch. No other terminal needs it."
        case "com.googlecode.iterm2", "com.apple.Terminal":
            return "Tintpad opens your terminal with AppleScript, so macOS asks for Automation once, on first launch. That's the only prompt."
        case "":
            return "Depending on your terminal, macOS may ask once for Automation (iTerm2/Terminal) or Accessibility (Ghostty). Nothing is asked up front."
        default:
            return "No extra permissions needed — Tintpad launches your terminal directly."
        }
    }

    @ViewBuilder
    private func step<C: View>(_ n: Int, _ title: String, _ subtitle: String,
                               @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(accent, in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                control()
            }
        }
    }
}
