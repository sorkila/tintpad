import AppKit
import SwiftUI

@main
struct TintpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Tintpad", systemImage: "command") {
            Button("Summon palette") { delegate.panelController.show() }
                .keyboardShortcut(.space, modifiers: [.option, .command])
            Divider()
            Text("Hotkey: ⌥⌘Space (spike default)")
            Divider()
            Button("Quit Tintpad") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let panelController = CommandPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory app: no Dock icon, never steals the active app on launch.
        NSApp.setActivationPolicy(.accessory)

        HotkeyManager.configureSpikeDefaultIfNeeded()
        HotkeyManager.onSummon { [weak self] in
            self?.panelController.toggle()
        }

        // Spike diagnostics: log the four unknowns at launch.
        logSpikeDiagnostics()
    }

    private func logSpikeDiagnostics() {
        print("── Tintpad Phase 0 spike ─────────────────────────────")
        print("login shell : \(ShellEnvironment.loginShell)")
        print("resolved PATH entries: \(ShellEnvironment.resolvedPath.split(separator: ":").count)")
        for bin in ["claude", "codex", "aider"] {
            let r = ShellEnvironment.resolveBinary(bin) ?? "<not found>"
            print("  resolve \(bin): \(r)")
        }
        let installed = TerminalRegistry.installed.map(\.displayName).joined(separator: ", ")
        print("terminals   : \(installed.isEmpty ? "<none detected>" : installed)")
        print("preferred   : \(TerminalRegistry.preferred.displayName)")
        print("hotkey      : ⌥⌘Space — press to summon")
        print("──────────────────────────────────────────────────────")
        fflush(stdout)
    }
}
