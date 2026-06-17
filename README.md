# Tintpad — Phase 0 Spike

A keyboard-first macOS launcher: summon a palette, fuzzy-find a repo, pick an
agent + run mode, and your terminal opens at that repo with the agent running.

This is the **Phase 0 de-risking spike**. Its only job is to prove the four
unknowns that determine whether the product is feasible:

| # | Unknown | Status | Evidence |
|---|---------|--------|----------|
| a | Non-activating `NSPanel` that takes typing and returns focus on close | ⏳ needs GUI check | `CommandPanel.swift` / `CommandPanelController` |
| b | Global hotkey in a menu-bar (accessory) app | ⏳ needs GUI check | KeyboardShortcuts, ⌥⌘Space |
| c | Login-shell PATH resolution for agent binaries | ✅ **proven** | `claude`→`~/.local/bin`, `codex`→fnm path resolved at launch |
| d | Terminal handoff end-to-end (≥2 adapters) | ⏳ needs GUI check | Ghostty (live), iTerm2 / WezTerm / Terminal.app written |

## Architecture

- `ShellEnvironment.swift` — resolves the interactive login-shell PATH
  (`zsh -lic`) + probes well-known install dirs, so GUI-launched Tintpad finds
  `claude`/`codex`/`aider` that launchd's minimal PATH would miss.
- `TerminalAdapter.swift` — `TerminalAdapter` protocol + per-terminal launchers.
  Ghostty/WezTerm use CLI flags; iTerm2/Terminal.app use AppleScript `do script`.
  Detection is bundle-id based via `NSWorkspace`.
- `CommandPanel.swift` — `NSPanel` subclass (`.nonactivatingPanel`) hosting
  SwiftUI via `NSHostingView`; closes on Esc / focus loss and returns focus.
- `PaletteView.swift` — the palette UI: repo discovery, frecency-ready list,
  Claude Code agent with Safe / Default / **YOLO** run modes, live command preview.
- `HotkeyManager.swift` — KeyboardShortcuts wiring (spike default ⌥⌘Space).
- `TintpadApp.swift` — `MenuBarExtra` accessory app; logs spike diagnostics.

## Run it

```sh
swift run
```

The app appears as a `command` icon in the menu bar (no Dock icon). Launch
diagnostics print to stdout.

### Manual verification checklist (the GUI unknowns)

1. **Hotkey (b):** press **⌥⌘Space** anywhere → palette appears centered.
2. **Panel focus (a):** start typing immediately (no extra click) → query
   filters. Press **Esc** → palette closes and focus returns to your previous
   app (the app never stole the menu bar).
3. **Handoff (d):** select a repo, press **↵** → Ghostty opens at that path
   running `claude`. Press **⌥↵** instead → launches with
   `--dangerously-skip-permissions` (YOLO).
4. The footer always shows the exact resolved command before you launch.

> Spike caveats: a global hotkey and AppleScript-driven terminals (iTerm2 /
> Terminal.app) trigger macOS TCC prompts; allow them. iTerm2 is not installed
> on the dev machine, so its adapter is written but untested here.
