<div align="center">

<img src="docs/assets/icon.png" width="116" alt="Tintpad" />

# Tintpad

**Your agent. Your repo. One keystroke.**

A macOS hotkey that opens your terminal at the right repo with Claude Code, Codex,
or whatever you run, already going.

[![CI](https://github.com/sorkila/tintpad/actions/workflows/ci.yml/badge.svg)](https://github.com/sorkila/tintpad/actions/workflows/ci.yml)
&nbsp;![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000)
&nbsp;![Swift 6](https://img.shields.io/badge/Swift-6-orange)
&nbsp;![License: MIT](https://img.shields.io/badge/license-MIT-blue)

</div>

---

Press <kbd>⌥⌘Space</kbd>. Fuzzy-find a repo. Hit <kbd>↵</kbd>. Your real terminal opens
there with the agent running, in under two seconds, without the mouse.

It hands off to the terminal you already use. It doesn't try to be one.

> Not a usage monitor. Not an IDE. Not a terminal. The launcher the agent menu-bar apps forgot.

<div align="center">
  <img src="docs/assets/demo.gif" alt="Tintpad: summon → fuzzy-find a repo → your terminal opens there with the agent running" width="640" />
</div>

<!-- Drop the recording at docs/assets/demo.gif, see docs/DEMO.md for the 60-second how-to. -->

## Why

GUI apps don't inherit your shell `PATH`, so double-clicking an app can't find
`claude` or `codex`. Repo-switching is friction. Tintpad fixes both: it resolves your
login-shell `PATH` once, ranks repos by frecency, and hands the command to your terminal
at the right directory. The boring 2-second thing you do twenty times a day, gone.

## Install

**[Download the latest signed, notarized `Tintpad.dmg`](https://github.com/sorkila/tintpad/releases/latest/download/Tintpad.dmg)**,
drag it to Applications, and launch. macOS 14+.
(Or browse all [releases](https://github.com/sorkila/tintpad/releases).)

Or with Homebrew:

```sh
brew install --cask sorkila/tap/tintpad
```

Or build from source (macOS 14+, Swift 6 toolchain / Xcode 16+):

```sh
git clone https://github.com/sorkila/tintpad.git
cd tintpad
swift run                  # dev run
./Scripts/package.sh       # build Tintpad.app into .build/release
```

## Features

- **Frecency repo search**, your most-used repos rise to the top, zoxide-style.
- **Hands off to 7 terminals**, Ghostty, iTerm2, kitty, WezTerm, Alacritty, Terminal, Warp.
- **Run modes**, Safe / Default / YOLO map to each agent's flags. The dangerous one is marked, never silent.
- **Worktrees**, <kbd>⌃W</kbd> spins up an isolated branch checkout and launches the agent in it.
- **Headless dispatch**, <kbd>⌃↵</kbd> runs an agent in the background and notifies you when it's done.
- **Prompt library, per-repo presets, GitHub import, open-in-editor.**
- **Local-only.** No accounts, no telemetry, nothing leaves your Mac.

## Keys

| Key | Action |
|---|---|
| <kbd>⌥⌘Space</kbd> | Summon (change in Settings → Hotkeys) |
| <kbd>↑</kbd> / <kbd>↓</kbd> | Navigate |
| <kbd>↵</kbd> | Launch default agent + mode |
| <kbd>⌘↵</kbd> | Open repo in editor |
| <kbd>⌥↵</kbd> | Launch YOLO (dangerous) |
| <kbd>⇧↵</kbd> | Launch Safe |
| <kbd>⌃↵</kbd> | Headless dispatch |
| <kbd>⌃W</kbd> | New worktree |
| <kbd>⇥</kbd> / <kbd>⇧⇥</kbd> | Cycle agent / mode |
| <kbd>⌘L</kbd> · <kbd>⌘P</kbd> | Inline prompt · cycle saved prompt |
| <kbd>⌘R</kbd> · <kbd>Esc</kbd> | Re-scan repos · close |

## Configure

Agents are just command templates with variables, set them in **Settings → Agents**:

```
claude {mode} {prompt}
```

Variables: `{repoPath}` `{repoName}` `{branch}` `{remote}` `{prompt}` `{mode}` `{shell}` `{worktreePath}`.
Every interpolated value is sanitized and shell-quoted before it runs.

## Contributing

PRs welcome, **especially new terminal adapters**, which are about one protocol and one
struct. See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Support

Tintpad is **free and MIT**, the whole thing. If it earns a spot in your day, leave a tip:
[**Buy me a coffee →**](https://www.buymeacoffee.com/eriknielsen). Supporters get custom
accent tints and my thanks, that's the only difference. To claim the tints, tip then email
your receipt to [erik@sorkila.com](mailto:erik@sorkila.com) and I'll send you an unlock key
(it verifies offline, no account).

## License

[MIT](LICENSE) © 2026 Erik Nielsen ([Sörkila](https://sorkila.com))
