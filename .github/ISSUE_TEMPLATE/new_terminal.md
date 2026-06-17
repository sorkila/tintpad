---
name: Terminal support
about: Request or offer a new terminal adapter
title: "terminal: <name>"
labels: terminal-adapter, good first issue
---

**Which terminal**
Name + bundle identifier (e.g. `com.example.MyTerm`) + download link.

**How does it open a window at a directory running a command?**
- [ ] CLI flag (best — like kitty/Alacritty: `myterm --dir X -e "cmd"`)
- [ ] AppleScript `do script` (like Terminal/iTerm2)
- [ ] Keystroke injection (last resort — like Ghostty)
- [ ] No command API (clipboard fallback — like Warp)

Paste the exact command/flags if you know them.

**Offering a PR?**
Great — see the adapter guide in [CONTRIBUTING.md](../CONTRIBUTING.md). It's one
protocol + one struct + one line in `TerminalRegistry.all`.
