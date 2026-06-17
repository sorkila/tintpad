import AppKit
import SwiftUI

@main
struct TintpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = AppStore.shared

    var body: some Scene {
        MenuBarExtra("Tintpad", systemImage: "command") {
            Button("Summon palette") { delegate.panelController.show() }
                .keyboardShortcut(.space, modifiers: [.option, .command])
            Divider()
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)
            Button("Re-scan repos") {
                let n = store.runAutoDiscovery()
                NSLog("Tintpad: discovered \(n) new repos")
            }
            Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
                .disabled(!UpdaterController.shared.canCheckForUpdates)
            Divider()
            Button("Quit Tintpad") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }

        SwiftUI.Settings {
            SettingsView(store: store)
                .preferredColorScheme(store.settings.appearance == .dark ? .dark : nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let panelController = CommandPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HotkeyManager.configureSpikeDefaultIfNeeded()
        HotkeyManager.onSummon { [weak self] in
            self?.panelController.toggle()
        }
        HotkeyManager.onResumeLast {
            if !LaunchService.resumeLast(store: AppStore.shared) {
                NSSound.beep()
            }
        }

        // Populate repos in the background so the first summon is instant.
        let added = AppStore.shared.runAutoDiscovery()
        if added > 0 { NSLog("Tintpad: discovered \(added) repos at launch") }

        // Ask for notification permission so headless dispatch can notify on done.
        DispatchService.shared.requestAuthorization()
    }
}
