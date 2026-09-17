import AppKit
import ApplicationServices
import Foundation

/// A launch request: open a terminal at `workingDirectory` and run `command`.
struct TerminalLaunch: Sendable {
    /// Absolute, canonicalized repo path.
    let workingDirectory: String
    /// The full command to run (binary already resolved to an absolute path).
    let command: String
    /// Open in a new tab rather than a new window, where the terminal supports
    /// it. CLI-only terminals (kitty/Alacritty/WezTerm/Warp) ignore this.
    var openInTab: Bool = false
}

/// Result of a launch. `note` carries user-facing info (e.g. Warp's clipboard
/// fallback) without being an error.
struct LaunchOutcome: Sendable {
    var note: String?
}

/// What an adapter's main-actor preflight hands back: the launch already done
/// (quick AppKit calls, like Warp's pasteboard), or the blocking rest of it,
/// which `LaunchService` runs on a GCD queue so no handoff holds the main
/// thread (an AppleScript handoff once did, for up to ~8.5s on a cold Ghostty).
enum TerminalHandoff: Sendable {
    case done(LaunchOutcome)
    case blocking(@Sendable () throws -> LaunchOutcome)
}

/// The System Settings pane a permission failure resolves in. Carried on the
/// error (not just named in prose) so the palette can open it on ⏎ instead of
/// asking the user to find it.
enum PrivacyPane: String, Sendable {
    case accessibility = "Privacy_Accessibility"
    case automation = "Privacy_Automation"

    /// Opens the pane. For Accessibility, first fires the system prompt —
    /// it adds Tintpad to the list by itself, which the pane alone won't do.
    @MainActor func open() {
        if self == .accessibility {
            // Literal value of kAXTrustedCheckOptionPrompt (that global isn't
            // concurrency-safe under Swift 6).
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum TerminalLaunchError: Error, CustomStringConvertible, LocalizedError {
    case notInstalled
    case launchFailed(String)
    /// A TCC grant is missing — or stale: macOS keys grants to the app's code
    /// signature, so a grant made to a differently signed build shows as
    /// enabled in System Settings yet silently fails to apply. `summary` is
    /// short enough for the drop's one-line status, `remedy` carries the full
    /// instructions (including the stale case) for surfaces with room.
    case permissionNeeded(summary: String, remedy: String, pane: PrivacyPane)

    var description: String {
        switch self {
        case .notInstalled: return "That terminal isn't installed."
        case .launchFailed(let m): return "Couldn't open the terminal: \(m)"
        case .permissionNeeded(let summary, let remedy, _): return "\(summary). \(remedy)"
        }
    }
    var errorDescription: String? { description }
}

/// One implementation per terminal app. Detection is bundle-id based; launch
/// uses whichever mechanism is most reliable for that terminal.
///
/// A launch has two halves. `prepare` runs on the main actor and reads the
/// AppKit state the launch depends on (installed, TCC trust, whether the app
/// is already running), throwing the actionable errors at once. The
/// `TerminalHandoff` it returns carries the blocking half (subprocesses,
/// `osascript`), which must not touch AppKit. Call through
/// `LaunchService.handOff`, never directly.
protocol TerminalAdapter: Sendable {
    var displayName: String { get }
    var bundleID: String { get }
    var isInstalled: Bool { get }
    @MainActor func prepare(_ launch: TerminalLaunch) throws -> TerminalHandoff
}

extension TerminalAdapter {
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

// MARK: - Shared helpers

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A shell script that cd's into the repo, runs the command, then drops into an
/// interactive login shell so the window stays open and PATH/aliases are loaded.
private func keepOpenScript(_ launch: TerminalLaunch) -> String {
    let shell = ShellEnvironment.loginShell
    return "cd \(shellQuote(launch.workingDirectory)) && \(launch.command); exec \(shell) -i"
}

/// Program + args that run the keep-open script through the user's login shell.
private func shellProgram(_ launch: TerminalLaunch) -> [String] {
    [ShellEnvironment.loginShell, "-i", "-c", keepOpenScript(launch)]
}

/// Runs a foreground helper, throwing on nonzero exit with captured stderr.
/// Bounded: a launcher helper that takes 15s is broken, not busy — hanging
/// the app on it would be worse (AUDIT 2026-07).
private func run(_ executable: String, _ args: [String]) throws {
    let result: ProcessRunner.Output
    do {
        result = try ProcessRunner.run(executable, arguments: args,
                                       environment: ShellEnvironment.processEnvironment,
                                       timeout: 15)
    } catch {
        throw TerminalLaunchError.launchFailed("\(executable): \(error.localizedDescription)")
    }
    if result.status != 0 {
        throw TerminalLaunchError.launchFailed(
            "exited \(result.status): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

/// Launches a new instance of a bundled app, passing args to it via `open`.
private func openApp(bundleID: String, args: [String]) throws {
    try run("/usr/bin/open", ["-nb", bundleID, "--args"] + args)
}

// MARK: - Ghostty (CLI via `open`)

/// Ghostty is single-instance on macOS: `+new-window` is unsupported, `open -n`
/// runs the command in a window-less second instance, and `open` without `-n`
/// ignores args. The only reliable way to drive a *running* Ghostty is to open a
/// new window (⌘N) and type the command — via System Events (needs Accessibility
/// permission, prompted on first use).
///
/// A cold start is different: `activate` *launches* Ghostty, which opens its own
/// initial window, so sending ⌘N on top of that leaves a second, blank window
/// (the "two Ghosttys on the day's first launch" bug). When Ghostty wasn't
/// already running, the script instead types into the window the launch itself
/// produces, polling for the process and window (a cold start takes seconds
/// where a warm activate is instant), with ⌘N only as a fallback for
/// `initial-window = false` configs.
struct GhosttyAdapter: TerminalAdapter {
    let displayName = "Ghostty"
    let bundleID = "com.mitchellh.ghostty"

    @MainActor func prepare(_ launch: TerminalLaunch) throws -> TerminalHandoff {
        guard isInstalled else { throw TerminalLaunchError.notInstalled }
        // Ghostty handoff types the command via System Events, which needs
        // Accessibility. Without it the keystrokes silently no-op — so fail loudly
        // instead. (Rebuilding an unsigned app resets this grant in macOS.)
        guard AXIsProcessTrusted() else {
            throw TerminalLaunchError.permissionNeeded(
                summary: "Ghostty needs Accessibility",
                remedy: "Grant Tintpad in System Settings → Privacy & Security → Accessibility. If Tintpad is already listed, the grant has gone stale, remove it and add it back, then relaunch Tintpad.",
                pane: .accessibility)
        }
        let cmd = "cd \(shellQuote(launch.workingDirectory)) && \(launch.command)"
        // `isFinishedLaunching` counts: an instance still mid-launch is about to
        // open its initial window, exactly like the not-running case. Read
        // here, on main, before the script leaves for `osascript`.
        let wasRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains(where: \.isFinishedLaunching)
        let script = Self.handoffScript(command: cmd, openInTab: launch.openInTab, wasRunning: wasRunning)
        return .blocking {
            try AppleScriptRunner.run(script)
            return LaunchOutcome()
        }
    }

    /// The System Events script for each entry state. Pure so the branch is
    /// testable; the frontmost checks pin the target — if focus moved during
    /// the delays, the command must NOT be typed into whatever stole it.
    static func handoffScript(command: String, openInTab: Bool, wasRunning: Bool) -> String {
        let type = """
            if frontmost of process "Ghostty" is false then error "Ghostty lost focus, nothing was typed."
            keystroke "\(appleScriptEscape(command))"
            key code 36
        end tell
        """
        if wasRunning {
            let newKey = openInTab ? "t" : "n"   // ⌘T tab / ⌘N window
            return """
            tell application "Ghostty" to activate
            delay 0.35
            tell application "System Events"
                if frontmost of process "Ghostty" is false then error "Ghostty lost focus, nothing was typed."
                keystroke "\(newKey)" using command down
                delay 0.45
            \(type)
            """
        }
        // Cold start: bounded polls (~5s + ~3s worst case). The script runs
        // off main through `osascript`, and `AppleScriptRunner` bounds the
        // whole run too, so a hung launch fails rather than sitting forever.
        return """
        tell application "Ghostty" to activate
        tell application "System Events"
            repeat 20 times
                if (exists process "Ghostty") and frontmost of process "Ghostty" then exit repeat
                delay 0.25
            end repeat
            if (exists process "Ghostty") is false then error "Ghostty did not start, nothing was typed."
            if frontmost of process "Ghostty" is false then error "Ghostty lost focus, nothing was typed."
            repeat 12 times
                if (count of windows of process "Ghostty") > 0 then exit repeat
                delay 0.25
            end repeat
            if (count of windows of process "Ghostty") is 0 then keystroke "n" using command down
            delay 0.45
        \(type)
        """
    }
}

// MARK: - kitty (CLI via `open`)

struct KittyAdapter: TerminalAdapter {
    let displayName = "kitty"
    let bundleID = "net.kovidgoyal.kitty"

    @MainActor func prepare(_ launch: TerminalLaunch) throws -> TerminalHandoff {
        guard isInstalled else { throw TerminalLaunchError.notInstalled }
        let bundleID = bundleID
        let args = ["--directory", launch.workingDirectory] + shellProgram(launch)
        return .blocking {
            try openApp(bundleID: bundleID, args: args)
            return LaunchOutcome()
        }
    }
}

// MARK: - Alacritty (CLI via `open`)

/// `-e <command>` must come last; no IPC, a clean new process each time.
struct AlacrittyAdapter: TerminalAdapter {
    let displayName = "Alacritty"
    let bundleID = "org.alacritty"

    @MainActor func prepare(_ launch: TerminalLaunch) throws -> TerminalHandoff {
        guard isInstalled else { throw TerminalLaunchError.notInstalled }
        let bundleID = bundleID
        let args = ["--working-directory", launch.workingDirectory, "-e"] + shellProgram(launch)
        return .blocking {
            try openApp(bundleID: bundleID, args: args)
            return LaunchOutcome()
        }
    }
}

// MARK: - WezTerm (bundled CLI)

/// `open -a` does NOT pass cwd; must use the `wezterm` binary with an absolute
/// `--cwd` (Issue #6218: relative paths fall back to $HOME).
struct WezTermAdapter: TerminalAdapter {
    let displayName = "WezTerm"
    let bundleID = "com.github.wez.wezterm"

    @MainActor func prepare(_ launch: TerminalLaunch) throws -> TerminalHandoff {
        guard let app = appURL else { throw TerminalLaunchError.notInstalled }
        let bundled = app.appendingPathComponent("Contents/MacOS/wezterm").path
        let bin = FileManager.default.isExecutableFile(atPath: bundled)
            ? bundled
            : (ShellEnvironment.resolveBinary("wezterm") ?? bundled)
        let prog = shellProgram(launch)
        return .blocking {
            // Tab: spawn into the running GUI via the mux. Falls back to a new window
            // if WezTerm isn't already running (`cli spawn` needs a live gui server).
            if launch.openInTab,
               (try? run(bin, ["cli", "spawn", "--cwd", launch.workingDirectory, "--"] + prog)) != nil {
                return LaunchOutcome()
            }
            // With no GUI running, `wezterm start` IS the terminal process —
            // waiting for its exit would wait for the window to close.
            do {
                try ProcessRunner.spawnDetached(bin, arguments: ["start", "--cwd", launch.workingDirectory, "--"] + prog,
                                                environment: ShellEnvironment.processEnvironment)
            } catch {
                throw TerminalLaunchError.launchFailed("\(bin): \(error.localizedDescription)")
            }
            return LaunchOutcome()
        }
    }
}

// MARK: - iTerm2 (AppleScript)

/// Most scriptable. `write text` types-and-runs in a fresh session that stays
/// open. Triggers the macOS Automation (Apple Events) TCC prompt on first use.
struct ITerm2Adapter: TerminalAdapter {
    let displayName = "iTerm2"
    let bundleID = "com.googlecode.iterm2"

    @MainActor func prepare(_ launch: TerminalLaunch) throws -> TerminalHandoff {
        guard isInstalled else { throw TerminalLaunchError.notInstalled }
        let cmd = "cd \(shellQuote(launch.workingDirectory)) && \(launch.command)"
        // New tab in the current window (falling back to a new window if none),
        // or a fresh window.
        let make = launch.openInTab
            ? """
              if (count of windows) = 0 then
                  set s to current session of (create window with default profile)
              else
                  set s to current session of (create tab with default profile)
              end if
              """
            : "set s to current session of (create window with default profile)"
        let script = """
        tell application "iTerm2"
            \(make)
            tell s to write text "\(appleScriptEscape(cmd))"
            activate
        end tell
        """
        return .blocking {
            try AppleScriptRunner.run(script)
            return LaunchOutcome()
        }
    }
}

// MARK: - Terminal.app (AppleScript)

struct AppleTerminalAdapter: TerminalAdapter {
    let displayName = "Terminal"
    let bundleID = "com.apple.Terminal"

    @MainActor func prepare(_ launch: TerminalLaunch) throws -> TerminalHandoff {
        // The tab path types ⌘T via System Events, which needs Accessibility —
        // fail with the actionable message, not a raw AppleScript error.
        if launch.openInTab, !AXIsProcessTrusted() {
            throw TerminalLaunchError.permissionNeeded(
                summary: "Opening a Terminal tab needs Accessibility",
                remedy: "Grant Tintpad in System Settings → Privacy & Security → Accessibility, or switch off open-in-tab. If Tintpad is already listed, remove it and add it back.",
                pane: .accessibility)
        }
        let cmd = "cd \(shellQuote(launch.workingDirectory)) && \(launch.command)"
        // Window: `do script` opens a fresh window. Tab: there's no AppleScript
        // for "new tab", so open one with ⌘T (System Events) and run there.
        let script = launch.openInTab ? """
        tell application "Terminal" to activate
        if (count of windows of application "Terminal") = 0 then
            tell application "Terminal" to do script "\(appleScriptEscape(cmd))"
        else
            tell application "System Events" to keystroke "t" using command down
            delay 0.3
            tell application "Terminal" to do script "\(appleScriptEscape(cmd))" in front window
        end if
        """ : """
        tell application "Terminal"
            do script "\(appleScriptEscape(cmd))"
            activate
        end tell
        """
        return .blocking {
            try AppleScriptRunner.run(script)
            return LaunchOutcome()
        }
    }
}

// MARK: - Warp (open-at-path + clipboard fallback)

/// Warp has no supported command-injection API (issues #5405, #12343). We open
/// a new window at the path and copy the command to the clipboard.
struct WarpAdapter: TerminalAdapter {
    let displayName = "Warp"
    let bundleID = "dev.warp.Warp-Stable"

    /// The pasteboard and `NSWorkspace.open` are AppKit and quick, so they
    /// run here on main. Only the `open` fallback is blocking.
    @MainActor func prepare(_ launch: TerminalLaunch) throws -> TerminalHandoff {
        guard isInstalled else { throw TerminalLaunchError.notInstalled }
        let full = "cd \(shellQuote(launch.workingDirectory)) && \(launch.command)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(full, forType: .string)

        // URLComponents percent-encodes query values properly, so a path
        // containing "&" or "=" can't smuggle extra parameters into the action.
        var comps = URLComponents()
        comps.scheme = "warp"
        comps.host = "action"
        comps.path = "/new_window"
        comps.queryItems = [URLQueryItem(name: "path", value: launch.workingDirectory)]
        let note = LaunchOutcome(note: "Command copied, paste it in Warp")
        if let url = comps.url, NSWorkspace.shared.open(url) {
            return .done(note)
        }
        let bundleID = bundleID
        return .blocking {
            try run("/usr/bin/open", ["-nb", bundleID])
            return note
        }
    }
}

// MARK: - AppleScript

/// Escape a string for embedding in an AppleScript double-quoted literal.
/// Order matters: backslash first (so the quote-escape's backslashes aren't
/// re-escaped), then the double quote, then collapse CR/LF to spaces.
func appleScriptEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
     .replacingOccurrences(of: "\r", with: " ")
     .replacingOccurrences(of: "\n", with: " ")
}

/// Runs AppleScript through `osascript` under `ProcessRunner`, never in
/// process: in-process AppleScript must run on the main thread and blocks it for as
/// long as the script takes, which froze the drop mid-launch and left it
/// unable to answer AppKit's own deactivation (the stranded-shadow bug).
///
/// The script goes in on stdin, so a command (and any prompt in it) never
/// shows in a process listing. The child gets the same scrubbed environment
/// as every spawn (`ShellEnvironment.processEnvironment`), and TCC attributes
/// it to Tintpad as the responsible process, so existing Automation and
/// Accessibility grants carry over.
enum AppleScriptRunner {
    /// Longer than the cold Ghostty script's own ~8.5s of polls, and long
    /// enough for a first-run Automation consent prompt, which holds the
    /// Apple event (and so `osascript`) until the user answers it.
    static let timeout: TimeInterval = 60

    nonisolated static func run(_ source: String) throws {
        let result = try ProcessRunner.run(
            "/usr/bin/osascript", arguments: ["-"],
            environment: ShellEnvironment.processEnvironment,
            input: Data(source.utf8), timeout: timeout)
        if let error = classify(status: result.status, stderr: result.stderr) { throw error }
    }

    /// Pure: turn `osascript`'s exit status and stderr into the launch error
    /// the drop can act on. Nil on success.
    ///
    /// osascript reports `<range>: execution error: <message> (<number>)`.
    /// -1743 (not authorized) and -1744 (consent would be needed) are
    /// Automation. 1002 ("not allowed to send keystrokes") and -1719 ("not
    /// allowed assistive access") are Accessibility, the System Events
    /// keystroke path. Anything else is a plain failure carrying the message.
    nonisolated static func classify(status: Int32, stderr: String) -> TerminalLaunchError? {
        guard status != 0 else { return nil }
        let raw = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains("(-1743)") || raw.contains("(-1744)") {
            return .permissionNeeded(
                summary: "Tintpad isn't allowed to control your terminal",
                remedy: "Allow it in System Settings → Privacy & Security → Automation, then try again. If Tintpad is already allowed, the grant has gone stale, remove it and add it back.",
                pane: .automation)
        }
        if raw.contains("(1002)") || raw.contains("(-1719)")
            || raw.localizedCaseInsensitiveContains("not allowed to send keystrokes")
            || raw.localizedCaseInsensitiveContains("not allowed assistive access") {
            return .permissionNeeded(
                summary: "Typing into your terminal needs Accessibility",
                remedy: "Grant Tintpad in System Settings → Privacy & Security → Accessibility. If Tintpad is already listed, the grant has gone stale, remove it and add it back, then relaunch Tintpad.",
                pane: .accessibility)
        }
        let message = cleanMessage(raw)
        return .launchFailed(message.isEmpty ? "exited \(status): " : "AppleScript: \(message)")
    }

    /// "12:40: execution error: Ghostty lost focus. (-2700)" → "Ghostty lost focus."
    nonisolated static func cleanMessage(_ stderr: String) -> String {
        var m = stderr.split(separator: "\n").first.map(String.init) ?? ""
        if let r = m.range(of: "error: ") { m = String(m[r.upperBound...]) }
        if let r = m.range(of: #"\s*\(-?\d+\)$"#, options: .regularExpression) { m.removeSubrange(r) }
        return m.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Registry

enum TerminalRegistry {
    static let all: [TerminalAdapter] = [
        GhosttyAdapter(),
        KittyAdapter(),
        AlacrittyAdapter(),
        WezTermAdapter(),
        ITerm2Adapter(),
        AppleTerminalAdapter(),
        WarpAdapter(),
    ]

    static var installed: [TerminalAdapter] {
        all.filter(\.isInstalled)
    }

    static func adapter(forBundleID id: String?) -> TerminalAdapter? {
        guard let id else { return nil }
        return all.first { $0.bundleID == id }
    }

    /// The adapter to launch into: the user's preference if installed, else the
    /// first installed terminal, with Terminal.app as the always-present fallback.
    static func preferred(settings: Settings) -> TerminalAdapter {
        if let chosen = adapter(forBundleID: settings.preferredTerminalBundleID), chosen.isInstalled {
            return chosen
        }
        return installed.first ?? AppleTerminalAdapter()
    }
}
