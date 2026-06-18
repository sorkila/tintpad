# Architecture

Native Swift/SwiftUI menu-bar (accessory) app. SPM executable, no external app framework.

## Data
- `Models.swift` — Codable `Repo`, `Agent`, `RunMode`, `Settings`, `TintAccent`; seed agents (Claude Code, Codex). Tolerant decoders so adding fields never reseeds the store.
- `Store.swift` — `AppStore` (`@MainActor ObservableObject`), JSON at `~/Library/Application Support/Tintpad/store.json`. Frecency recording, auto-discovery, the (tip-jar) `allows(_:)` entitlement check.

## Services
- `Frecency.swift` — `fre`-style continuous half-life decay ranking.
- `GitInfo.swift` — parses `.git/HEAD` + `.git/config` directly (no subprocess).
- `CommandTemplate.swift` — variable substitution + login-shell binary resolution. **All interpolated values are sanitized (control chars stripped) and single-quoted** — the injection surface, unit-tested.
- `RepoDiscovery.swift` — scans root folders 1–2 levels deep for `.git`.
- `ShellEnvironment.swift` — resolves the interactive login-shell PATH (with a timeout, off the main thread) so a GUI-launched app finds `claude`/`codex`/… (the #1 footgun).
- `WorktreeService.swift`, `DispatchService.swift`, `GitHubService.swift`, `Keychain.swift`, `LaunchService.swift`.

## Terminal handoff
- `TerminalAdapter.swift` — a `Sendable` protocol + 7 adapters. Ghostty / kitty / Alacritty via `open` CLI flags (Ghostty needs an Accessibility keystroke — single-instance limitation); WezTerm via bundled binary; iTerm2 / Terminal.app via AppleScript `do script`; Warp via open-at-path + clipboard fallback (no command API). See [CONTRIBUTING](../CONTRIBUTING.md) to add one.

## UI
- `CommandPanel.swift` — `.nonactivatingPanel` `NSPanel` hosting SwiftUI; returns focus on Esc / focus-loss; follows the chosen theme.
- `PaletteView.swift` — the palette: frecency list, agent cycling (⇥), modifier modes (⌥ YOLO / ⇧ Safe), dangerous-mode confirm, git branch + live command preview. A scoped `NSEvent` key monitor drives navigation (`.onKeyPress` on a `TextField` swallows arrows).
- `SettingsView.swift` (+ per-pane views) — native `NavigationSplitView` preferences.
- `LicenseManager.swift` — Ed25519 offline verification (the optional Supporter tip).
- `HotkeyManager.swift` — KeyboardShortcuts global summon. `TintpadApp.swift` — `MenuBarExtra` accessory app.

## Tests
`swift test` — pure-logic unit tests (frecency, command-template sanitization/injection, license verify, git parse, discovery). `Scripts/uitest.sh` — synthetic-input GUI smoke test (local only; needs Accessibility/Automation grants).

See also: [`AUDIT.md`](AUDIT.md) (security/quality), [`RELEASE.md`](RELEASE.md), [`HOMEBREW.md`](HOMEBREW.md).
