# Architecture

Native Swift/SwiftUI menu-bar (accessory) app. SPM executable, no external app framework.

## Data
- `Models.swift`, Codable `Repo`, `Agent`, `RunMode`, `Settings`, seed agents (Claude Code, Codex). Tolerant decoders so adding fields never reseeds the store. `LaunchDefaults` is the pure launch-resolution precedence: override → per-repo pin → last-used → agent default.
- `Store.swift`, `AppStore` (`@MainActor ObservableObject`), JSON at `~/Library/Application Support/Tintpad/store.json`. Frecency recording, background auto-discovery, debounced settings writes, the (tip-jar) `allows(_:)` entitlement check. A store that fails to load is preserved as `store.corrupt-<ts>.json`, never overwritten by a reseed. `SingleInstance.swift` flocks a sidecar so two instances can't clobber each other's writes.

## Services
- `Frecency.swift`, `fre`-style continuous half-life decay ranking.
- `GitInfo.swift`, parses `.git/HEAD` + `.git/config` directly (no subprocess).
- `CommandTemplate.swift`, variable substitution + login-shell binary resolution. **All interpolated values are sanitized (control chars stripped) and single-quoted**, the injection surface, unit-tested.
- `RepoDiscovery.swift`, scans root folders 1–2 levels deep for `.git`.
- `ShellEnvironment.swift`, resolves the interactive login-shell PATH (with a timeout, off the main thread) so a GUI-launched app finds `claude`/`codex`/… (the #1 footgun).
- `ProcessRunner.swift`, the one way subprocesses run: hard timeout, concurrently drained pipes (no 64KB deadlock), SIGTERM then SIGKILL, plus `spawnDetached` for processes that *are* the thing being opened. Backs the terminal-adapter helper, worktree git, and the async GitHub clone.
- `GitStatus.swift`, "is this working tree dirty" via a bounded `git status --porcelain` (first-byte read, never takes the index lock). `RepoTint.swift`, every repo's stable identity hue and short name.
- `WorktreeService.swift`, `DispatchService.swift`, `GitHubService.swift`, `Keychain.swift`, `LaunchService.swift`.

## Terminal handoff
- `TerminalAdapter.swift`, a `Sendable` protocol + 7 adapters. Ghostty / kitty / Alacritty via `open` CLI flags (Ghostty needs an Accessibility keystroke, single-instance limitation), WezTerm via bundled binary, iTerm2 / Terminal.app via AppleScript `do script`, Warp via open-at-path + clipboard fallback (no command API). See [CONTRIBUTING](../CONTRIBUTING.md) to add one.

## UI
- `CommandPanel.swift`, a **borderless** `.nonactivatingPanel` `NSPanel` at `.statusBar` level (it draws over the menu bar strip to fuse with the camera housing), forced darkAqua, returns focus on Esc / focus-loss. `dock()` computes the summon screen's notch geometry per show (`safeAreaInsets.top`) and bridges it to SwiftUI via `NotchAnchor`; notched screens dock flush with the screen top, plain screens just below the menu bar. The window draws **no system shadow**; the drop casts its own inside a transparent margin, and `resize(toContentHeight:)` still reads the real safe-area insets (zero today) so a future style change can't silently clip.
- `PaletteView.swift`, the palette: **the drop**, a pure-black capsule that falls out of the notch (bead → fall → splat → settle, springs throughout, crossfade under Reduce Motion). Stark black and white: gray repo tokens, a white selection chip with black ink, and the contract as two etched instrument chips (AGENT and MODE, micro-label eyebrows, never truncated), with the permission-skipping mode red-etched and every dangerous path routed through one confirm gate (`fireOrConfirm`). Fully mute at rest: tokens only, the query materializes as you type. A scoped `NSEvent` key monitor drives navigation (`.onKeyPress` on a `TextField` swallows arrows), and ←/→ move through tokens only while the field is empty. `KeyPolicy` decides when Tab belongs to focus traversal instead of agent cycling.
- `AgentMarks.swift`, the agent's brand mark (shown beside its name in the launch pill and in Settings), rasterized on demand at the exact pixel size it will be drawn, with a per-brand optical correction so an airy mark and a dense one carry the same ink. `Monogram.swift` assigns distinct letters across the whole agent set (`AppStore.monogram(for:)` is the single source of truth).
- `Tokens.swift`, spacing, radii, and the scalable `TypeRamp` used by the resizable surfaces.
- `SettingsView.swift` (+ per-pane views), native `NavigationSplitView` preferences.
- `LicenseManager.swift`, Ed25519 offline verification (the optional Supporter tip).
- `HotkeyManager.swift`, KeyboardShortcuts global summon. `TintpadApp.swift`, `MenuBarExtra` accessory app.

## Tests
`swift test`, pure-logic unit tests (frecency incl. clock-rollback clamping, command-template sanitization/injection, launch-default precedence, git parse + dirty detection, repo tints and short names, license verify, discovery, monogram assignment, Tab policy). [`TESTING.md`](TESTING.md) is the journey-based synthetic user testing plan. `Scripts/uitest.sh`, synthetic-input GUI smoke test (local only, needs Accessibility/Automation grants). `TINTPAD_SHOWCASE=1` summons the palette at launch and holds it open for screenshots, see [DEMO.md](DEMO.md).

See also: [`AUDIT.md`](AUDIT.md) (security/quality), [`RELEASE.md`](RELEASE.md), [`HOMEBREW.md`](HOMEBREW.md).
