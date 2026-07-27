# Good first issues

Small, real, well-scoped. Pick one, open a PR. Read
[CONTRIBUTING.md](../CONTRIBUTING.md) and
[docs/ARCHITECTURE.md](ARCHITECTURE.md) first. `swift build && swift test`
should be green before you start.

Each issue below maps to actual code. Paths are under `Sources/Tintpad/`.
Anything marked **✅ Shipped** has already landed and is kept here only so the
numbering stays stable, please skip those.

---

## 1. Add a "new tab" option to the WezTerm adapter

**Labels:** `enhancement`, `terminal-adapter`, `good first issue`
**Difficulty:** medium

`WezTermAdapter` in `TerminalAdapter.swift` always opens a new window via the
bundled `wezterm` binary. Plenty of people live in one window and want a new tab
instead. Add a per-terminal "new tab vs new window" preference (mirror however
the other adapters expose launch options) and have the adapter pass the
`wezterm cli spawn` path for tabs, falling back to a fresh window when no GUI is
running. Keep the command build going through `CommandTemplate` / `shellQuote`, no hand-concatenated paths.

**Acceptance criteria**

- A toggle exists to launch WezTerm in a new tab.
- Tab mode reuses the running GUI, if WezTerm isn't running, it opens a window.
- Window mode behaves exactly as today (no regression).
- The launched shell starts in the canonicalized repo path with the command run.
- A test covers the command string for both modes.

---

## 2. Add a brand-new terminal adapter

**Labels:** `enhancement`, `terminal-adapter`, `good first issue`
**Difficulty:** easy

This is the single most useful thing you can contribute, and it's small. Pick a
terminal Tintpad doesn't support yet (Rio, Tabby, Hyper, your favorite) and add
a `struct` conforming to `TerminalAdapter` in `TerminalAdapter.swift`, then
register it in `TerminalRegistry.all`. Prefer a CLI flag over AppleScript, fall
back to `do script` or keystrokes only if there's no command API. The protocol
and a worked example are in CONTRIBUTING.md under "Adding a terminal adapter."

**Acceptance criteria**

- New `TerminalAdapter` type with correct `displayName`, `bundleID`, and
  `isInstalled`.
- Registered in `TerminalRegistry.all`.
- `launch(_:)` opens at `workingDirectory` and runs `command`, any path goes
  through `shellQuote`.
- Adapter is hidden when the app isn't installed.
- PR notes how you tested it (`./Scripts/uitest.sh` or an eyeball launch).

---

## 3. Fix the Tab / Shift-Tab VoiceOver keyboard trap in the palette

**✅ Shipped.** `PaletteView` no longer swallows Tab when VoiceOver or Full
Keyboard Access is active, so focus traversal works normally (`KeyPolicy`, unit
tested). Ordinary keyboard use keeps ⇥ and ⇧⇥ for cycling agent and mode, and
the footer's "agent" and "mode" hints are labelled buttons carrying the same
actions for anyone who cannot use the shortcut.

---

## 4. Support Dynamic Type in settings and onboarding

**Labels:** `enhancement`, `accessibility`, `good first issue`
**Difficulty:** medium

`PaletteView` is done: its type and grid metrics scale together with
`@ScaledMetric`, which they have to, because the panel's computed height is
derived from those metrics. Roughly ten hard-coded `.font(.system(size:))` calls
remain in `OnboardingView.swift` and `SettingsView.swift`. Replace those with
semantic text styles (the shared `TypeRamp` in `Tokens.swift` is the intended
home) and check nothing clips or overlaps at the larger sizes.

**Acceptance criteria**

- Settings and onboarding respect the system text-size and accessibility sizes.
- Larger sizes don't clip, truncate badly, or break layout.
- Default size looks the same as before.
- Screenshots at default and a large accessibility size in the PR.

---

## 5. Add a dispatch-log viewer in Settings

**Labels:** `enhancement`, `good first issue`
**Difficulty:** medium

When a launch misfires, there's nowhere to see what happened. Have
`DispatchService.swift` keep a small in-memory ring buffer of recent dispatches
(timestamp, repo, terminal, the final command, success/failure) and add a
read-only list view to Settings to show it. Local-only, in-memory, no file on
disk unless you want a "copy to clipboard" button. No telemetry.

**Acceptance criteria**

- `DispatchService` records the last N dispatches in memory.
- A Settings pane lists them, newest first, with status.
- Failures show the error, successes show the command that ran.
- Buffer is bounded and resets on relaunch, nothing is sent anywhere.

---

## 6. Break frecency ties deterministically

**✅ Shipped.** `Frecency.ordered` breaks equal scores by most-recent-launch then
name, covered by `testEqualScoresBreakTieByRecencyThenName`. Note for anyone
touching it: the comparator must stay **transitive**, so no epsilon "close
enough" tie band. That breaks strict weak ordering and makes `sort()` reshuffle
the list on every render.

---

## 7. Replace raw Swift errors with human-readable messages

**Labels:** `enhancement`, `good first issue`
**Difficulty:** easy

When a launch fails, users currently see raw `Error` text (think
`The operation couldn't be completed. (Tintpad.LaunchError error 2.)`). Give the
error types in `DispatchService.swift` / `LaunchService.swift` a
`LocalizedError` conformance with plain-language `errorDescription`s ("WezTerm
isn't installed", "Couldn't read that repo path") and surface those in the
palette instead of the underlying error. Keep the raw error available for the
dispatch log (issue 5) if it lands.

**Acceptance criteria**

- Launch/dispatch failures conform to `LocalizedError` with clear messages.
- The palette shows the friendly message, not the raw Swift error.
- Each known failure mode (missing terminal, bad path, command failure) has its
  own message.
- A test checks the message for at least one failure case.

---

## 8. Record a demo GIF for the README

**✅ Shipped**, and now **out of date**. `docs/assets/demo.gif` and the site's
`web/assets/demo.mp4`, `demo-poster.jpg` and `og.png` all show the pre-HUD
palette, so they advertise a UI that no longer exists. Re-shooting them is a
genuinely useful contribution. See [DEMO.md](DEMO.md), which now documents the
`TINTPAD_SHOWCASE=1` capture harness.
