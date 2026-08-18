# Synthetic user testing

Scripted journeys that drive the real app the way a person does: summon, type,
arrow, launch, and then assert on what actually happened. This complements the
unit suite (pure logic) and replaces hope with evidence for the GUI layer.

## Harness architecture

Everything builds on the pattern in `Scripts/uitest.sh`:

- **Controlled store.** Back up `~/Library/Application Support/Tintpad/store.json`,
  write a known store (two marker agents, one test repo, Terminal.app handoff),
  restore on exit via `trap`. Launches are safe because the "agents" are
  `touch /tmp/tp_A; echo {mode} > /tmp/tp_A_flags` templates, so every launch
  leaves a marker whose *content* proves which mode flags were passed.
- **Synthetic input.** `osascript` System Events keystrokes and key codes.
  Requires Accessibility (send keys) and Automation (drive Terminal) for the
  runner, which makes this a local, real-session suite, not a CI job. CI keeps
  the unit tests, this suite runs before releases.
- **Store assertions.** After a journey, read `store.json` with python and
  assert on `sessions`, `lastAgentID`, `lastModeID`, frecency bumps.
- **Visual probes.** `TINTPAD_SHOWCASE=1` summons the palette at launch, keeps
  it up on focus loss, and writes the panel rect to `/tmp/tintpad-panel-rect`
  so `screencapture -R` can crop exactly. `TINTPAD_SHOWCASE_SETTINGS=1` does the
  same for Settings, and `TINTPAD_SCREEN_PRIMARY=1` pins the drop to the primary
  display so a capture rect is reproducible across sessions. Probes sample small
  regions (is the MODE chip red, is the selected chip white on black), never
  full-image golden diffs. The drop is pure black and white with one red, so a
  region probe is a stable assertion rather than a screenshot to re-bless.
- **Flake control.** Never sleep-and-pray for launches: poll for the marker
  file with a timeout (`wait_marker`). Retry a journey once before failing it,
  and report retries, a journey that only passes on retry is a bug report on
  the harness.

## The keymap under test

Summon is the global hotkey (⌥⌘Space by default). Inside the drop:

| Key | Does |
|-----|------|
| ↑ / ↓ | move through repos, always |
| ← / → | move through repos, only while the query is empty and no mode is armed |
| ⏎ | launch the contract the chips state |
| ⇧⏎ | launch with the first non-dangerous mode |
| ⌘⏎ | open the repo in your editor instead |
| ⌃⏎ | headless dispatch, notifies when done |
| ⇥ / ⇧⇥ | cycle agent / cycle mode (yields to focus traversal under VoiceOver or Full Keyboard Access) |
| ⌘1 to ⌘9 | jump to that repo and launch it, no arrowing |
| ⌘0 | resume the last session |
| ⌘L | capture a one-off starting prompt |
| ⌃W | worktree mode, isolated checkout on a new branch |
| ⌘P | cycle the saved starting prompt |
| ⌘R | rescan the root folders |
| ⌘, | Settings |
| esc | dismiss, returning focus to the previous app |

The ⌘1 to ⌘9 numbers are not drawn on the tokens (the drop is mute at rest),
but they are live, and VoiceOver announces each token's number.

## Journeys

### What the harness seeds

Two repos. `tintpad-uitest` is **pinned** and answers to agent TestA, and
`tintpad-zzother` is **unpinned** and answers to TestB. The pin is what makes
the suite deterministic: `Frecency.ordered` puts pinned repos ahead of
everything, so row 1 stays row 1 even though each launch bumps a score, whereas
an unpinned winner would quietly reorder the list under the next journey.

TestA carries two modes, a `Default` with no flags and a permission-skipping
`Skip permissions` with `--test-danger`. Both agents' templates write the
resolved flags to a marker (`echo "[{mode}]" > /tmp/tp_A_flags`), so a journey
can assert on *what ran*, not merely that something did. Terminal.app is the
handoff, onboarding is marked done, and a license key is injected.

The brackets in that template are load-bearing: they keep `{mode}` off a space
boundary, where `CommandTemplate`'s empty-slot cleanup would otherwise eat the
surrounding text. `UITestHarnessContractTests` in the unit suite pins that
rendering, so a change to how `{mode}` is substituted fails in CI rather than
silently hollowing out J4.

### Implemented in `Scripts/uitest.sh`

| # | Journey | Steps | Assert |
|---|---------|-------|--------|
| J1 | Launch the obvious thing | summon, ⏎ | `/tmp/tp_A` marker appears |
| J2 | Type to filter | summon, type "zzother", ⏎ | `/tmp/tp_B` appears **and** `/tmp/tp_A` does not, so the query really moved the selection to row 2 |
| J3 | Switch agent | summon, ⇥, ⏎ | `/tmp/tp_B` marker, so ⇥ really changed the agent |
| J4 | Switch mode | summon, ⇧⇥, ⏎ | the marker's *content* holds `--test-danger`, so ⇧⇥ really changed the mode |
| J5 | Prompt mode | summon, ⌘L, type "hello", ⏎ | the session records `prompt == "hello"` |
| J6 | Escape is free | summon, esc | no marker |

J2 and J4 were both near-worthless until the seed store grew: J2 filtered a
list of one, and J4 cycled a single mode through a template that never
interpolated `{mode}`. Each passed whether or not the keystroke did anything.
The lesson generalizes, a journey that cannot fail for the right reason is
decoration, so give every new one a way to come out wrong.

### Planned, the harness has the helpers but not the journeys

These need a third repo so that arrowing and ⌘3 have somewhere distinct to
land. `Charlie` below is that repo.

| # | Journey | Steps | Assert |
|---|---------|-------|--------|
| J7 | Arrow the strip | summon, → →, ⏎ | Charlie's marker, the third token |
| J8 | Jump shortcut | summon, ⌘3 | Charlie's marker without any arrowing |
| J9 | Danger needs consent | `confirmDangerousModes` on, ⇧⇥ to `Skip permissions`, ⏎ | no marker yet, the confirm line arms, a second ⏎ produces it |
| J10 | Resume | J1 first, summon, ⌘0 | row 1's marker again, sessions deduped to one |
| J11 | The app remembers | J4 first, summon again | the MODE chip states `Skip permissions`, and ⏎ passes `--test-danger` |
| J12 | Worktree mode | summon, ⌃W, type a branch, ⏎ | the worktree dir exists and the marker ran inside it |
| J13 | Dispatch is not a back door | ⇧⇥ to `Skip permissions`, ⌃⏎ with confirm on | dispatch waits at the same gate a plain ⏎ would |
| J14 | Fresh session | launch from a terminal already inside an agent session | the launched command carries the `env -u` prefix and the child sees no inherited session markers |

J3, J4, and J11 are the ones the old row UI could not honestly test. The
contract chips now *state* the plan before ⏎, so a region probe on the chip
row double-checks what the marker content proves.

J9 and J13 matter most. Every dangerous path routes through one gate
(`PaletteModel.fireOrConfirm`), and the audit that introduced it found five
ways around that gate. A new launch path is not done until it has a journey
here.

## Accessibility pass (manual, per release)

- VoiceOver: summon, arrow the strip. Each token announces name, agent, mode,
  pinned, and its ⌘ number. Rotor actions "Switch agent" and "Switch mode"
  work without ⇥. The confirm line announces itself when it arms.
- Full Keyboard Access: ⇥ traverses instead of cycling agents (`KeyPolicy`),
  and the AGENT and MODE chips are reachable as real buttons.
- System text size at AX5: Settings and onboarding reflow via `TypeRamp`, the
  drop scales with `@ScaledMetric` and caps at xxLarge by design (one line
  cannot absorb accessibility sizes).
- Reduce Motion: the drop crossfades in rather than dripping, falling, and
  splatting, no stagger on the tokens, and the strip's edge fade does not
  animate.
- Contrast: the selected chip is white with black ink, tokens are gray on pure
  black, and the only color in the drop is danger red. Nothing meaningful is
  drawn in tertiary ink.

Reduce Transparency needs no check. Nothing in the product is translucent
any more: the drop is opaque black and the Settings sidebar is a solid fill,
chosen precisely so the wallpaper could not tint a monochrome room.

## What stays manual

- **The floating-pill fallback.** Displays without a notch get the same drop
  hanging below the menu bar. The notched path is verified on the built-in
  display, the floating path is the one that goes unlooked at, so put the drop
  on an external monitor before a release.
- **The adapter matrix.** Actual terminal handoff to all seven adapters,
  exercised by launching each at least once before a release. Terminal.app and
  iTerm2 need Automation, Ghostty needs Accessibility, the CLI terminals need
  neither, and Warp falls back to the clipboard.
- **The permission-failure line.** A launch with a missing Accessibility or
  Automation grant must show the red one-liner in the drop, and ⏎ must open the
  named System Settings pane. A dev build cannot reproduce the missing-grant
  state on a granted machine (TCC matches the bundle ID, so the dev build
  inherits the grant and really launches), so verify with a temporary forced
  throw in the adapter, never by resetting the machine's real grants.
- **Sparkle update flow**, from an older installed build through to relaunch.
- **System-drawn surfaces.** The folder chooser and the reset alert are drawn
  by macOS, not by us. `AppAppearance.applyProductTheme()` pins darkAqua
  app-wide so they match, and that is only provable by opening them on a Mac
  set to Light.

There is no light-mode pass any more. The product has one black world and no
theme setting.

## Cadence

- Full journey suite: before every release, via `Scripts/uitest.sh`.
- J1, J6, J9 as a smoke trio: after any change to the palette or a launch path.
