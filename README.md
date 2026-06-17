# Tintpad

A keyboard-first macOS launcher: summon a palette, fuzzy-find a repo, pick an
agent + run mode, and your terminal opens at that repo with the agent running —
in under two seconds, without the mouse.

Native Swift/SwiftUI menu-bar (accessory) app. Local-only, no accounts.
Distributed direct (Developer ID + notarization), not the Mac App Store.

## Status: Phase 2 (v1)

Phase 1 (MVP):

| Capability | State |
|---|---|
| Global hotkey → non-activating palette → frecency repo search | ✅ |
| Repo management: manual add, drag-drop, auto-discover, frecency ranking | ✅ |
| User-defined agents with command templates + Safe/Default/YOLO run modes | ✅ |
| Run-mode selection: per-agent default, per-repo override, launch modifiers | ✅ |
| Dangerous-mode confirm + warning tint | ✅ |
| Terminal handoff to 7 terminals | ✅ |
| First-class Settings + tint design system + JSON persistence | ✅ |

Phase 2 (v1):

| Capability | State |
|---|---|
| Open-in-editor (⌘↵) — VS Code / Cursor / Zed / Sublime / JetBrains | ✅ |
| Prompt library — saved prompts, ⌘P to attach at launch | ✅ |
| Recent sessions + quick-resume (instant resume-last hotkey) | ✅ |
| Pro licensing — Ed25519 offline verification + feature gating | ✅ |
| Per-repo presets (agent + mode + pin) | ✅ |
| Notarized DMG + Homebrew cask | ⏳ scaffolded (`Scripts/package.sh`, needs Developer ID) |
| Sparkle auto-update, GTM launch | ⏳ Phase 3 / non-code |

### Pro vs Free

Free: core launch flow forever, up to 3 agents, Safe/Default modes, default tint.
Pro (one-time unlock): unlimited agents, YOLO modes, prompt library, per-repo
presets, custom tints. Licenses are Ed25519-signed and verified offline (no
phone-home). The signing key lives only in `secrets/` (gitignored); the public
key is embedded in `LicenseManager.swift`.

## Architecture

**Data layer**
- `Models.swift` — Codable `Repo`, `Agent`, `RunMode`, `Settings`, `TintAccent`,
  seed agents (Claude Code, Codex).
- `Store.swift` — `AppStore` (`ObservableObject`), JSON persistence to
  `~/Library/Application Support/Tintpad/store.json`.

**Services**
- `Frecency.swift` — `fre`-style continuous half-life decay ranking.
- `GitInfo.swift` — parses `.git/HEAD` + `.git/config` directly (no subprocess).
- `CommandTemplate.swift` — variable substitution + login-shell binary resolution.
- `RepoDiscovery.swift` — scans root folders 1–2 levels deep for `.git`.
- `ShellEnvironment.swift` — resolves the interactive login-shell PATH so a
  GUI-launched app finds `claude`/`codex`/… (the #1 footgun).

**Terminal handoff**
- `TerminalAdapter.swift` — protocol + 7 adapters. Ghostty / kitty / Alacritty
  via `open` CLI flags; WezTerm via bundled binary; iTerm2 / Terminal.app via
  AppleScript; Warp via open-at-path + clipboard fallback (no command-injection API).

**UI**
- `CommandPanel.swift` — `.nonactivatingPanel` `NSPanel` hosting SwiftUI;
  returns focus on Esc / focus-loss.
- `PaletteView.swift` — the palette: frecency list, agent cycling (⇥), modifier
  modes (⌥ YOLO / ⇧ Safe), dangerous-mode confirm, git branch + live command preview.
- `SettingsView.swift` + `HotkeysSettingsView` / `ReposSettingsView` /
  `AgentsSettingsView` — the native preferences window.
- `HotkeyManager.swift` — KeyboardShortcuts global summon.
- `TintpadApp.swift` — `MenuBarExtra` accessory app + `Settings` scene.

## Run

```sh
swift run                 # dev
./Scripts/package.sh      # assemble Tintpad.app (unsigned)
```

To sign + notarize, set `SIGN_IDENTITY` and `NOTARY_PROFILE` and re-run the script.

### Palette keys

| Key | Action |
|---|---|
| ⌥⌘Space | Summon (spike default; change in Settings → Hotkeys) |
| ↑ / ↓ | Navigate |
| ⏎ | Launch default agent + mode |
| ⌘⏎ | Open repo in editor |
| ⌥⏎ | Launch YOLO (dangerous; second ⏎ confirms; Pro) |
| ⇧⏎ | Launch Safe |
| ⇥ | Cycle agent |
| ⌘P | Cycle attached prompt (Pro) |
| ⌘R | Re-scan repos |
| Esc | Close (returns focus to previous app) |

### Notes / Phase 2

- Hotkey currently seeds ⌥⌘Space; production onboarding should prompt instead.
- AppleScript terminals (iTerm2/Terminal.app) trigger an Automation TCC prompt —
  the bundled `Info.plist` carries `NSAppleEventsUsageDescription`.
- Pro licensing (Lemon Squeezy/Paddle), Sparkle updates, per-repo prompt
  library, recent sessions, worktrees → Phase 2/3.
