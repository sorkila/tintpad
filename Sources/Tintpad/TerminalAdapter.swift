import AppKit
import Foundation

/// A launch request: open a terminal at `workingDirectory` and run `command`.
struct TerminalLaunch {
    /// Absolute, canonicalized repo path.
    let workingDirectory: String
    /// The full shell command to run, e.g. `claude --dangerously-skip-permissions`.
    /// Already binary-resolved and assembled by the caller.
    let command: String
}

enum TerminalLaunchError: Error, CustomStringConvertible {
    case notInstalled
    case launchFailed(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .notInstalled: return "Terminal app is not installed."
        case .launchFailed(let m): return "Launch failed: \(m)"
        case .unsupported(let m): return "Unsupported: \(m)"
        }
    }
}

/// One implementation per terminal app. Detection is bundle-id based; launch
/// uses whichever mechanism is most reliable for that terminal (CLI flags,
/// `open -na`, or AppleScript).
protocol TerminalAdapter: Sendable {
    /// Human-facing name, e.g. "Ghostty".
    var displayName: String { get }
    /// Bundle identifier used for detection.
    var bundleID: String { get }
    /// Whether the app is installed on this machine.
    var isInstalled: Bool { get }
    /// Open a window/tab at the path with the command running.
    func launch(_ launch: TerminalLaunch) throws
}

extension TerminalAdapter {
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// URL of the installed app bundle, if any.
    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

// MARK: - Shared helpers

private func shellQuote(_ s: String) -> String {
    // Single-quote and escape embedded single quotes the POSIX way.
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Runs a foreground process (used for `open` and CLI launchers), throwing on
/// nonzero exit with captured stderr.
private func run(_ executable: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    p.environment = ShellEnvironment.processEnvironment
    let err = Pipe()
    p.standardError = err
    p.standardOutput = Pipe()
    do {
        try p.run()
    } catch {
        throw TerminalLaunchError.launchFailed("\(executable): \(error.localizedDescription)")
    }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw TerminalLaunchError.launchFailed("\(executable) exited \(p.terminationStatus): \(msg)")
    }
}

// MARK: - Ghostty (CLI via `open -na`)

/// `+new-window` does not work on macOS; `open -na` with `--working-directory`
/// and `-e <cmd>` is the reliable path.
struct GhosttyAdapter: TerminalAdapter {
    let displayName = "Ghostty"
    let bundleID = "com.mitchellh.ghostty"

    func launch(_ launch: TerminalLaunch) throws {
        guard isInstalled else { throw TerminalLaunchError.notInstalled }
        // Run the command, then drop into an interactive shell so the window
        // stays open after the agent exits.
        let inner = "cd \(shellQuote(launch.workingDirectory)) && \(launch.command); exec \(ShellEnvironment.loginShell) -i"
        try run("/usr/bin/open", [
            "-na", "Ghostty",
            "--args",
            "--working-directory=\(launch.workingDirectory)",
            "-e", inner,
        ])
    }
}

// MARK: - WezTerm (CLI)

/// `open -a` does NOT pass cwd; must use the `wezterm` binary directly with an
/// absolute `--cwd` (Issue #6218: relative paths fall back to $HOME).
struct WezTermAdapter: TerminalAdapter {
    let displayName = "WezTerm"
    let bundleID = "com.github.wez.wezterm"

    func launch(_ launch: TerminalLaunch) throws {
        guard let app = appURL else { throw TerminalLaunchError.notInstalled }
        // Prefer the CLI shipped inside the bundle to avoid PATH ambiguity.
        let bundled = app.appendingPathComponent("Contents/MacOS/wezterm").path
        let bin = FileManager.default.isExecutableFile(atPath: bundled)
            ? bundled
            : (ShellEnvironment.resolveBinary("wezterm") ?? bundled)

        let inner = "\(launch.command); exec \(ShellEnvironment.loginShell) -i"
        try run(bin, [
            "start",
            "--cwd", launch.workingDirectory,
            "--", ShellEnvironment.loginShell, "-i", "-c", inner,
        ])
    }
}

// MARK: - iTerm2 (AppleScript)

/// Most scriptable terminal. `do script` types-and-runs. Triggers the macOS
/// Automation (Apple Events) TCC prompt on first use.
struct ITerm2Adapter: TerminalAdapter {
    let displayName = "iTerm2"
    let bundleID = "com.googlecode.iterm2"

    func launch(_ launch: TerminalLaunch) throws {
        guard isInstalled else { throw TerminalLaunchError.notInstalled }
        let cmd = "cd \(shellQuote(launch.workingDirectory)) && \(launch.command)"
        // Escape for embedding inside an AppleScript double-quoted string.
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            create window with default profile command "\(ShellEnvironment.loginShell) -i -c \\"\(escaped)\\""
            activate
        end tell
        """
        try AppleScriptRunner.run(script)
    }
}

// MARK: - Terminal.app (AppleScript)

struct AppleTerminalAdapter: TerminalAdapter {
    let displayName = "Terminal"
    let bundleID = "com.apple.Terminal"

    func launch(_ launch: TerminalLaunch) throws {
        let cmd = "cd \(shellQuote(launch.workingDirectory)) && \(launch.command)"
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            do script "\(escaped)"
            activate
        end tell
        """
        try AppleScriptRunner.run(script)
    }
}

// MARK: - AppleScript runner

enum AppleScriptRunner {
    static func run(_ source: String) throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw TerminalLaunchError.launchFailed("could not compile AppleScript")
        }
        script.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            throw TerminalLaunchError.launchFailed("AppleScript: \(msg)")
        }
    }
}

// MARK: - Registry

enum TerminalRegistry {
    static let all: [TerminalAdapter] = [
        GhosttyAdapter(),
        WezTermAdapter(),
        ITerm2Adapter(),
        AppleTerminalAdapter(),
    ]

    static var installed: [TerminalAdapter] {
        all.filter { $0.isInstalled }
    }

    /// The adapter we'll launch into by default: first installed, with
    /// Terminal.app as the always-present fallback.
    static var preferred: TerminalAdapter {
        installed.first ?? AppleTerminalAdapter()
    }
}
