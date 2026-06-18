# Good first issues

Small, real, well-scoped. Pick one, open a PR. Read
[CONTRIBUTING.md](../CONTRIBUTING.md) and
[docs/ARCHITECTURE.md](ARCHITECTURE.md) first. `swift build && swift test`
should be green before you start.

Each issue below maps to actual code. Paths are under `Sources/Tintpad/`.

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

**Labels:** `bug`, `accessibility`, `good first issue`
**Difficulty:** medium

VoiceOver users can get stuck in `PaletteView.swift`: Tab and Shift-Tab don't
move focus the way the rotor expects, so the palette becomes a trap. Audit the
focus order and `focusable` / `accessibility` modifiers so Tab cycles forward,
Shift-Tab cycles back, and focus can always leave the field and the results
list. Don't break the existing arrow-key + Enter dispatch flow.

**Acceptance criteria**

- Tab and Shift-Tab move focus predictably through search field and results.
- VoiceOver can enter and exit the palette without getting stuck.
- Arrow-key navigation and Enter-to-dispatch still work unchanged.
- Verified with VoiceOver on (note the steps in the PR).

---

## 4. Support Dynamic Type in the palette and settings

**Labels:** `enhancement`, `accessibility`, `good first issue`
**Difficulty:** medium

Fixed point sizes mean the app ignores the system text-size setting. Replace
hard-coded `.font(.system(size:))` calls with semantic text styles (or scale
them with `@ScaledMetric`) in `PaletteView.swift` and the settings views so
layout follows accessibility text sizes. Check that rows don't clip or overlap
at the larger sizes.

**Acceptance criteria**

- Palette and main settings respect the system text-size / accessibility sizes.
- Larger sizes don't clip, truncate badly, or break row layout.
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

**Labels:** `enhancement`, `good first issue`
**Difficulty:** easy

When two repos have an equal decayed score in `Frecency.swift`, ordering is
undefined, so the palette list can shuffle between launches. Add a stable
tie-break, most recently visited first, then name, so equal-score repos always
sort the same way. Touch only the comparator, don't change the decay math.

**Acceptance criteria**

- Equal-score repos sort by most-recent-visit, then by name.
- Ordering is stable across relaunches for unchanged data.
- The decay/score calculation is unchanged.
- A test asserts the tie-break order.

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

**Labels:** `docs`, `good first issue`
**Difficulty:** easy

The README tells, a GIF shows. Record a short loop of the hotkey summoning the
palette, picking a repo, and an agent landing in the terminal at that repo. Keep
it tight (a few seconds), reasonably sized, and drop it in `docs/assets/`, then
reference it near the top of `README.md`.

**Acceptance criteria**

- Short looping GIF (a few seconds) saved under `docs/assets/`.
- Shows: summon palette, pick repo, agent opens in terminal at that repo.
- Embedded in `README.md`.
- File size is sane for a README (compress it).
