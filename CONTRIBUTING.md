# Contributing to Tintpad

Thanks for being here. Tintpad is a small, native Swift app, PRs, issues, and
terminal adapters are all welcome.

## Getting set up

```sh
git clone https://github.com/sorkila/tintpad.git
cd tintpad
swift build && swift test     # should be green
swift run                     # runs the app
./Scripts/package.sh          # assembles Tintpad.app
```

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16+). Read
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the lay of the land.

## Ground rules

- Match the surrounding style: comment density, naming, idioms. No new dependencies without a reason.
- Keep it native and local-only. No telemetry, no network calls except the features that already make them (GitHub import, Sparkle).
- Anything that builds a shell command must go through `CommandTemplate` (values are sanitized + shell-quoted there). Don't interpolate untrusted strings into commands or AppleScript yourself.
- Run `swift test` before opening a PR. Add a test when you fix a bug or add logic.

## Adding a terminal adapter

This is the most useful thing you can contribute, and it's small. An adapter is one
type conforming to `TerminalAdapter` in `Sources/Tintpad/TerminalAdapter.swift`:

```swift
protocol TerminalAdapter: Sendable {
    var displayName: String { get }
    var bundleID: String { get }
    var isInstalled: Bool { get }
    @discardableResult
    func launch(_ launch: TerminalLaunch) throws -> LaunchOutcome
}

struct TerminalLaunch {
    let workingDirectory: String   // absolute, canonicalized repo path
    let command: String            // full command, binary already absolute
}
```

Steps:

1. Add a `struct MyTermAdapter: TerminalAdapter`.
   - `bundleID`, the app's bundle identifier (e.g. `"com.example.MyTerm"`).
   - `isInstalled`, usually `NSWorkspace.shared.urlForApplication(withBundleIdentifier:) != nil`.
   - `launch(_:)`, open a new window/tab at `launch.workingDirectory` and run `launch.command`. Prefer a CLI flag (like kitty/Alacritty) over AppleScript, fall back to AppleScript `do script` (like Terminal/iTerm2) or keystrokes (Ghostty) only if there's no command API.
2. Register it in `TerminalRegistry.all` (line ~264).
3. If you build the command string, **reuse the existing `shellQuote` helper**, never hand-concatenate paths.
4. Test it: add `TestA`/`TestB` marker agents and run `./Scripts/uitest.sh`, or just launch and eyeball it.

Open a PR titled `terminal: add <name>` with a one-line note on how you tested it.

## Reporting bugs / requesting features

Use the issue templates. For anything security-sensitive (command/AppleScript injection,
permission misuse), see [SECURITY.md](SECURITY.md) and report privately first.

## License

By contributing you agree your contributions are licensed under the [MIT License](LICENSE).
