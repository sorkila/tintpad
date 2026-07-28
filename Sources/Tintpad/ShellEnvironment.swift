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
    static let resolvedPath: String = {
        var entries: [String] = []
        if let shellPath = pathFromLoginShell() {
            entries.append(contentsOf: shellPath.split(separator: ":").map(String.init))
        }
        entries.append(contentsOf: probeDirectories)

        // De-dupe while preserving order.
        var seen = Set<String>()
        let ordered = entries.filter { seen.insert($0).inserted }
        return ordered.joined(separator: ":")
    }()

    /// Runs `<shell> -lic 'printf %s "$PATH"'` to capture the interactive
    /// login PATH. `-l` (login) sources zprofile, `-i` (interactive) sources
    /// zshrc — between them we get whatever the user actually sees in a terminal.
    private static func pathFromLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-lic", "printf %s \"$PATH\""]

        let pipe = Pipe()
        process.standardOutput = pipe
        // Null device, not an undrained Pipe: a chatty rc writing >64KB of
        // stderr noise would fill the buffer and wedge the shell until the
        // timeout, silently degrading PATH resolution for the whole session.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Bound the wait: a slow/hung shell rc must not block forever (we fall
        // back to the probe directories instead).
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolves an executable name (e.g. "claude") to an absolute path using the
    /// resolved PATH. Returns nil if not found anywhere.
    static func resolveBinary(_ name: String) -> String? {
        // Already absolute and executable? Trust it.
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let fm = FileManager.default
        for dir in resolvedPath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// An environment dictionary suitable for handing to `Process`, with our
    /// resolved PATH injected over the inherited (minimal) one.
    static var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = resolvedPath
        return env
    }
}
