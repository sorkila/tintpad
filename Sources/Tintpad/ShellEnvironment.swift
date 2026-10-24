import Foundation

/// Resolves the user's *interactive login shell* PATH so we can find agent
/// binaries (`claude`, `codex`, `aider`, …) that a GUI-launched app would
/// otherwise miss.
///
/// The footgun: an app launched from Finder/Dock/launchd inherits launchd's
/// minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), **not** the PATH your
/// `.zshrc`/`.zprofile` build. So `claude` (installed at `~/.local/bin`) or a
/// node-managed `codex` (under an fnm/nvm shim) simply won't be found.
///
/// Fix: ask the login shell to print its PATH (`zsh -lic`), cache it, and probe
/// a set of well-known install locations as a backstop.
enum ShellEnvironment {
    /// Common locations agent CLIs land in, used to backstop the shell probe.
    private static let probeDirectories: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",          // Apple-silicon Homebrew
            "/usr/local/bin",             // Intel Homebrew / misc
            "\(home)/.local/bin",         // pipx, claude installer
            "\(home)/.cargo/bin",         // rust tools
            "\(home)/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
    }()

    /// The user's login shell, e.g. `/bin/zsh`. Falls back to zsh.
    static var loginShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        // getpwuid is the authoritative source when SHELL is absent (GUI launch).
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            return String(cString: sh)
        }
        return "/bin/zsh"
    }

    /// The resolved PATH from the login shell, computed once and cached.
    /// Merges the shell's PATH with our probe directories so we degrade
    /// gracefully if the shell prints nothing useful.
    ///
    /// A `static let` holds every other accessor until the first one finishes,
    /// so it is pre-warmed off main at launch, and the probe runs through
    /// `ProcessRunner`, which waits on a semaphore and never pumps the run loop
    /// (an initializer that pumps it can re-enter a SwiftUI layout pass).
    static let resolvedPath: String = mergedPath(shell: pathFromLoginShell() ?? [],
                                                 probes: probeDirectories)

    /// The shell's entries first, then the probe directories, de-duplicated
    /// with order preserved. Pure.
    static func mergedPath(shell: [String], probes: [String]) -> String {
        var seen = Set<String>()
        return (shell + probes).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Bracket the PATH in the probe's output. Anything the user's rc prints to
    /// stdout (a greeting, an nvm notice, fastfetch, a `.zlogout` farewell)
    /// lands outside the markers instead of being fused onto the first entry.
    static let pathBeginMarker = "__TINTPAD_PATH_BEGIN__"
    static let pathEndMarker = "__TINTPAD_PATH_END__"

    /// The command the probe hands to `<shell> -lic`. Pure, so the per-shell
    /// quoting is testable.
    ///
    /// POSIX shells get `"$PATH"` quoted: bash word-splits and globs an
    /// unquoted expansion, and a PATH entry with a space would make `printf`
    /// recycle its format. fish is not POSIX: there `$PATH` is a list, and
    /// unquoted it expands to one argument per entry, so `printf '%s\n'` prints
    /// one entry per line on every fish version (quoted, fish 3 joins the list
    /// with colons but fish 2 joined it with spaces).
    static func pathProbeCommand(shell: String) -> String {
        let begin = "printf '\\n%s\\n' \(pathBeginMarker)"
        let end = "printf '%s\\n' \(pathEndMarker)"
        let path = (shell as NSString).lastPathComponent == "fish" ? "$PATH" : "\"$PATH\""
        return "\(begin); printf '%s\\n' \(path); \(end)"
    }

    /// The PATH entries between the last end marker and the last begin marker
    /// before it, split on newlines (fish) and colons (POSIX). Pure.
    ///
    /// Only whole marker lines count, so a marker quoted inside rc noise does
    /// not open a block. Only absolute entries survive: a relative entry would
    /// resolve against the GUI app's working directory (`/`), never the
    /// user's. Nil when either marker is missing or nothing usable is left,
    /// so the caller falls back to the probe directories.
    static func extractPath(from output: String) -> [String]? {
        // "\r\n" is one newline Character in Swift, so CRLF splits cleanly.
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        func isMarker(_ line: Substring, _ marker: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces) == marker
        }
        guard let end = lines.lastIndex(where: { isMarker($0, pathEndMarker) }),
              let begin = lines[..<end].lastIndex(where: { isMarker($0, pathBeginMarker) })
        else { return nil }
        let entries = lines[(begin + 1)..<end]
            .flatMap { $0.split(separator: ":") }
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        return entries.isEmpty ? nil : entries
    }

    /// The probe's attempts, in order. First `-lic`: `-l` (login) sources
    /// zprofile, `-i` (interactive) sources zshrc — between them we get
    /// whatever the user actually sees in a terminal. Only if that yields no
    /// PATH, `-lc`: login but not interactive, which skips an rc that ends in
    /// `exec tmux` or `exec fish` and still picks up fnm/nvm/volta shims set
    /// in the profile. Pure.
    static func probeArguments(shell: String) -> [[String]] {
        let command = pathProbeCommand(shell: shell)
        return [["-lic", command], ["-lc", command]]
    }

    /// Runs the probe attempts until one yields a PATH. `ProcessRunner`
    /// drains both pipes as data arrives, so an rc that prints more than a
    /// pipe's 64KB can't wedge the shell until the deadline, and a slow or
    /// hung rc is killed at 4s (then the next attempt, then the probe
    /// directories). stdin is an empty pipe closed at once, so an rc's
    /// `read`, `tmux attach` or `exec fish` can never grab the terminal of a
    /// developer running Tintpad from a TTY, it sees EOF instead.
    private static func pathFromLoginShell() -> [String]? {
        let shell = loginShell
        for arguments in probeArguments(shell: shell) {
            if let output = try? ProcessRunner.run(shell, arguments: arguments,
                                                   input: Data(), timeout: 4),
               let path = extractPath(from: output.stdout) {
                return path
            }
        }
        return nil
    }

    /// Resolves an executable name (e.g. "claude") to an absolute path using the
    /// resolved PATH. Returns nil if not found anywhere.
    static func resolveBinary(_ name: String) -> String? {
        resolveBinary(name, searchPath: resolvedPath)
    }

    /// `resolveBinary` against an explicit PATH, so it is testable without
    /// running the user's login shell.
    static func resolveBinary(_ name: String, searchPath: String) -> String? {
        let fm = FileManager.default
        // A directory carries an execute bit too, but it is never a binary.
        func isBinary(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
                && fm.isExecutableFile(atPath: path)
        }
        // Already absolute and executable? Trust it.
        if name.hasPrefix("/") {
            return isBinary(name) ? name : nil
        }
        for dir in searchPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if isBinary(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Env markers an agent session stamps on its children ("this process was
    /// spawned by session X"). A Tintpad launch is always a fresh, top-level,
    /// user-initiated session — never a child of another agent's session — so an
    /// inherited marker is always stale. The concrete harm: Claude Code silently
    /// stops saving transcripts (no resume) when CLAUDE_CODE_CHILD_SESSION leaks
    /// in from a terminal or launcher that was itself started inside a session.
    /// Only session-*instance* markers belong here; deliberate configuration
    /// (ANTHROPIC_API_KEY, CLAUDE_CONFIG_DIR, CLAUDE_EFFORT, …) is never touched,
    /// since a user may legitimately export those in their shell rc. Ordered, so
    /// the `env -u` prefix built from it is deterministic.
    static let sessionMarkers: [String] = [
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_PID",
        "CLAUDE_CODE_ENTRYPOINT",
    ]

    /// Remove inherited session markers from an environment. Pure, so the
    /// policy is testable without mutating the test process's real environment.
    static func scrubSessionMarkers(_ env: [String: String]) -> [String: String] {
        var scrubbed = env
        for marker in sessionMarkers { scrubbed[marker] = nil }
        return scrubbed
    }

    /// An environment dictionary suitable for handing to `Process`, with our
    /// resolved PATH injected over the inherited (minimal) one and stale
    /// session markers dropped.
    static var processEnvironment: [String: String] {
        var env = scrubSessionMarkers(ProcessInfo.processInfo.environment)
        env["PATH"] = resolvedPath
        return env
    }
}
