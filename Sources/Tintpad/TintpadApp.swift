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
        AppAppearance.apply(AppStore.shared.settings.appearance)

        // Pre-warm the login-shell PATH off the main thread. Doing it on a
        // background queue avoids both blocking launch on a slow shell rc and the
        // dispatch_once reentrancy that bit us when the first init ran during a
        // SwiftUI layout pass (waitUntilExit pumps the run loop).
        DispatchQueue.global(qos: .userInitiated).async { _ = ShellEnvironment.resolvedPath }
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

    /// `tintpad://` — summon the palette. Lets a Raycast script command (or any
    /// `open tintpad://`) trigger Tintpad without simulating the global hotkey.
    /// Summon-only by design: a URL never launches an agent on its own.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "tintpad" }) else { return }
        panelController.show()
    }
}
