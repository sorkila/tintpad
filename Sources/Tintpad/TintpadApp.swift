import AppKit
import SwiftUI

@main
struct TintpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = AppStore.shared
    @ObservedObject private var updater = UpdaterController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarIconShown) {
            Button("Summon palette") { delegate.panelController.show() }
                .keyboardShortcut(.space, modifiers: [.option, .command])
            // Every key the palette answers to, where macOS teaches shortcuts.
            // Rows are text, not commands: they only work inside the drop.
            Menu("Palette keys") {
                ForEach(PaletteKeys.all) { row in
                    Text("\(row.keys)    \(row.action)")
                }
            }
            // The resume affordance lives here, not as palette chrome — menus
            // are where macOS teaches shortcuts (⌘0 also works in the palette).
            Button("Resume last session") {
                LaunchService.resumeLast(store: store) { result in
                    if case .failure(let error) = result, !LaunchService.isInFlight(error) { NSSound.beep() }
                }
            }
            .disabled(!LaunchService.canResumeLast(store: store))
            Divider()
            Button("Settings…") { delegate.panelController.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button("Re-scan repos") {
                let n = store.runAutoDiscovery()
                NSLog("Tintpad: discovered \(n) new repos")
            }
            // A scheduled update waits here rather than in an alert behind the
            // user's work (see UpdaterController), so the item names it.
            if let version = updater.pendingVersion {
                Button("Update to \(version)…") { updater.checkForUpdates() }
            } else {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            Divider()
            Button("Quit Tintpad") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: updater.pendingVersion == nil ? MenuBarIcon.plain : MenuBarIcon.pendingUpdate)
        }
    }

    /// Settings → General decides, a waiting update overrides. ⌘-dragging the
    /// icon out of the menu bar writes the same setting the toggle does.
    /// SwiftUI writes this binding back on scene updates too, so the setter
    /// stores only a real removal (see `MenuBarIcon.settingAfterWrite`).
    private var menuBarIconShown: Binding<Bool> {
        Binding(
            get: { MenuBarIcon.isShown(setting: store.settings.showMenuBarIcon,
                                       pendingUpdate: updater.pendingVersion != nil) },
            set: { inserted in
                guard let setting = MenuBarIcon.settingAfterWrite(
                    inserted, setting: store.settings.showMenuBarIcon) else { return }
                store.settings.showMenuBarIcon = setting
                store.saveSoon()
            }
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let panelController = CommandPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the guard below, so even the "already running" alert arrives in
        // the black world rather than flashing white on a light Mac.
        AppAppearance.applyProductTheme()
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
            LaunchService.resumeLast(store: store) { result in
                if case .failure(let error) = result, !LaunchService.isInFlight(error) { NSSound.beep() }
            }
        }

        // Populate repos genuinely in the background — the scan can touch
        // slow fileprovider volumes and must never block launch.
        AppStore.shared.runAutoDiscoveryInBackground()

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
        // Self-driving demo (TINTPAD_DEMO=1): summon, then play a scripted
        // sequence on the model — no synthetic keystrokes, no TCC, perfectly
        // repeatable. Used to record the website video.
        if ProcessInfo.processInfo.environment["TINTPAD_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.panelController.show() }
            let model = panelController.model
            // The story in nine seconds: the fall, moving through repos
            // (the AGENT chip flips where a repo remembers Codex), a filter,
            // an agent cycle, the MODE chip turning red and back. Ends at
            // rest — the loop point is calm.
            // Paced as four acts — arrival, choosing, the contract, rest —
            // with air after every action so each one can be read. The cuts
            // in the edit land in the pauses, just before the next act.
            let beats: [(Double, @MainActor @Sendable () -> Void)] = [
                (3.0, { model.move(1) }),
                (3.7, { model.move(1) }),
                (4.4, { model.move(1) }),
                (5.4, { model.cycleAgent() }),
                (6.2, { model.cycleAgent() }),
                (7.0, { model.cycleMode() }),   // Skip permissions — red, held long
                (9.6, { model.cycleMode() }),   // back to Default, rest for the loop
            ]
            for (t, beat) in beats {
                DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: beat)
            }
            return
        }

        // First-run onboarding.
        if !AppStore.shared.settings.hasOnboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OnboardingWindowController.shared.show()
            }
        }
    }

    /// Opening Tintpad while it runs (Finder, Spotlight, the Dock) opens
    /// Settings, the way back when the menu bar icon is hidden. First-run
    /// setup, while it is up, comes forward instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if OnboardingWindowController.shared.isVisible {
            OnboardingWindowController.shared.show()
        } else {
            panelController.openSettings()
        }
        return false
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
