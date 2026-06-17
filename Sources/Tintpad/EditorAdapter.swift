import AppKit
import Foundation

/// Opens a repo folder in a code editor. Parallel to `TerminalAdapter` but
/// simpler: editors open a folder directly, no command injection needed.
///
/// Primary mechanism is `open -b <bundleID> <path>` (no PATH dependency, opens
/// the folder as a window/project). Falls back to the editor's CLI if the app
/// bundle isn't found but the CLI is on the login-shell PATH.
struct EditorApp: Identifiable, Sendable {
    let id: String        // bundleID
    let name: String
    let bundleID: String
    let cli: String       // e.g. "code", "cursor", "zed"

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        || ShellEnvironment.resolveBinary(cli) != nil
    }

    func open(path: String) throws {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            try runOpen(["-b", bundleID, path])
            return
        }
        if let bin = ShellEnvironment.resolveBinary(cli) {
            try runProcess(bin, [path])
            return
        }
        throw TerminalLaunchError.notInstalled
    }

    private func runOpen(_ args: [String]) throws { try runProcess("/usr/bin/open", args) }

    private func runProcess(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ShellEnvironment.processEnvironment
        p.standardError = Pipe(); p.standardOutput = Pipe()
        do { try p.run() } catch {
            throw TerminalLaunchError.launchFailed("\(exe): \(error.localizedDescription)")
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw TerminalLaunchError.launchFailed("\(name) exited \(p.terminationStatus)")
        }
    }
}

enum EditorRegistry {
    static let all: [EditorApp] = [
        EditorApp(id: "com.microsoft.VSCode", name: "VS Code",
                  bundleID: "com.microsoft.VSCode", cli: "code"),
        EditorApp(id: "com.todesktop.230313mzl4w4u92", name: "Cursor",
                  bundleID: "com.todesktop.230313mzl4w4u92", cli: "cursor"),
        EditorApp(id: "dev.zed.Zed", name: "Zed",
                  bundleID: "dev.zed.Zed", cli: "zed"),
        EditorApp(id: "com.sublimetext.4", name: "Sublime Text",
                  bundleID: "com.sublimetext.4", cli: "subl"),
        EditorApp(id: "com.jetbrains.intellij", name: "IntelliJ IDEA",
                  bundleID: "com.jetbrains.intellij", cli: "idea"),
    ]

    static var installed: [EditorApp] { all.filter(\.isInstalled) }

    static func editor(forID id: String?) -> EditorApp? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// User's chosen editor if installed, else the first detected one (or nil).
    static func preferred(settings: Settings) -> EditorApp? {
        if let chosen = editor(forID: settings.preferredEditorID), chosen.isInstalled {
            return chosen
        }
        return installed.first
    }
}
