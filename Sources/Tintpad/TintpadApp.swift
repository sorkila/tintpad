import AppKit
import SwiftUI

@main
struct TintpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = AppStore.shared

    /// Branded menu-bar glyph: the ⌘ mark in Tintpad orange.
    private static let menuIcon: NSImage = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(NSImage.SymbolConfiguration(
                paletteColors: [NSColor(srgbRed: 1.0, green: 0.45, blue: 0.20, alpha: 1)]))
        let img = NSImage(systemSymbolName: "command", accessibilityDescription: "Tintpad")?
            .withSymbolConfiguration(cfg) ?? NSImage()
        img.isTemplate = false
        return img
    }()

    var body: some Scene {
        MenuBarExtra {
            Button("Summon palette") { delegate.panelController.show() }
                .keyboardShortcut(.space, modifiers: [.option, .command])
            Divider()
            Button("Settings…") { delegate.panelController.openSettings() }
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
        } label: {
            Image(nsImage: Self.menuIcon)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let panelController = CommandPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Pre-warm the login-shell PATH now, once. Its lazy init spawns `zsh -lic`
        // and waitUntilExit() pumps the run loop; if that first init happens
        // during SwiftUI rendering it re-enters and trips dispatch_once (crash).
        _ = ShellEnvironment.resolvedPath
        panelController.warm()   // install key monitor before the first summon
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

        // First-run onboarding.
        if !AppStore.shared.settings.hasOnboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OnboardingWindowController.shared.show()
            }
        }
    }
}
