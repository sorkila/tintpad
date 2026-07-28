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
        // Two instances share one store.json and silently clobber each other —
        // refuse to be the second one (AUDIT 2026-07 #2).
        guard SingleInstance.acquire() else {
            NSLog("Tintpad: another instance is already running — quitting this one.")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Tintpad is already running"
            alert.informativeText = "Another copy of Tintpad has this Mac's data open. Quit it first if you meant to run this one."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
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
        HotkeyManager.onResumeLast { [weak self] in
            let store = AppStore.shared
            // A dangerous last session must not relaunch blind from a global
            // hotkey when confirmation is on — route it through the palette,
            // where the confirm banner has a surface (AUDIT 2026-07 #8).
            if store.settings.confirmDangerousModes,
               let s = store.lastSession, let agent = store.agent(s.agentID),
               agent.modes.first(where: { $0.id == s.modeID })?.isDangerous == true {
                self?.panelController.show()
                DispatchQueue.main.async { self?.panelController.model.resumeLastSession() }
                return
            }
            if case .launched = LaunchService.resumeLast(store: store) {} else {
                NSSound.beep()
            }
        }

        // Populate repos genuinely in the background — the scan can touch
        // slow fileprovider volumes and must never block launch.
        AppStore.shared.runAutoDiscoveryInBackground()

        // Ask for notification permission so headless dispatch can notify on done.
        DispatchService.shared.requestAuthorization()

        // Finishing onboarding summons the palette so the user lands in the app.
        NotificationCenter.default.addObserver(
            forName: .tintpadSummonPalette, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.panelController.show() }
        }

        // Screenshot harness: summon the palette straight away so it can be
        // captured without driving the global hotkey. See CommandPanelController.
        if CommandPanelController.isShowcase {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.panelController.show() }
            return
        }
        // Same harness for the Settings window (TINTPAD_SHOWCASE_SETTINGS=1).
        if ProcessInfo.processInfo.environment["TINTPAD_SHOWCASE_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.panelController.openSettings() }
            return
        }

        // First-run onboarding.
        if !AppStore.shared.settings.hasOnboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OnboardingWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A debounced settings write may still be pending — land it.
        AppStore.shared.flushPendingSave()
    }

    /// `tintpad://` — summon the palette. Lets a Raycast script command (or any
    /// `open tintpad://`) trigger Tintpad without simulating the global hotkey.
    /// Summon-only by design: a URL never launches an agent on its own.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "tintpad" }) else { return }
        panelController.show()
    }
}
