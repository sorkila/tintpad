# Synthetic user testing

Scripted journeys that drive the real app the way a person does: summon, type,
arrow, launch, and then assert on what actually happened. This complements the
unit suite (pure logic) and replaces hope with evidence for the GUI layer.

## Harness architecture

Everything builds on the pattern proven in `Scripts/uitest.sh`:

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
  so `screencapture -R` can crop exactly. Pixel probes sample small regions
  (is the danger ring red, is the selected tile brighter), not full-image
  golden diffs, which rot with every glass change.
- **Flake control.** Never sleep-and-pray for launches: poll for the marker
  file with a timeout (`wait_marker`). Retry a journey once before failing it,
  and report retries, a journey that only passes on retry is a bug report on
  the harness.

## Journeys

Each journey starts from a fresh summon of a known store. The store has repos
`Alpha` (agent TestA, Safe default), `Bravo` (TestA, Yolo-marked mode), and
`Charlie` (TestB), pinned in that order, so selection order is deterministic.

| # | Journey | Steps | Assert |
|---|---------|-------|--------|
| J1 | Launch the obvious thing | summon, ⏎ | Alpha marker exists, session recorded, panel closed |
| J2 | Type to filter | summon, type "cha", ⏎ | Charlie marker, filter count was shown |
| J3 | Arrow the strip | summon, → →, ⏎ | Charlie marker (third tile) |
| J4 | Jump shortcut | summon, ⌘3 | Charlie marker without any arrowing |
| J5 | Switch agent | summon, ⇥, ⏎ | Alpha launched with TestB's marker |
| J6 | Switch mode | summon, ⇧⇥, ⏎ | marker *content* holds the second mode's flags |
| J7 | Danger needs consent | store has confirmDangerousModes, select Bravo, ⏎ | no marker yet, second ⏎ produces it |
| J8 | Resume | J1 first, summon, ⌘0 | Alpha marker again, sessions deduped to one |
| J9 | The app remembers | J6 first, summon again | launch pill shows the remembered mode, ⏎ passes its flags |
| J10 | Escape is free | summon, esc | panel gone, no marker, previous app frontmost |
| J11 | Prompt mode | summon, ⌘L, type "fix tests", ⏎ | marker content contains the quoted prompt |
| J12 | Worktree mode | summon, ⌃W, type branch, ⏎ | worktree dir exists, marker ran inside it |

Journeys J5, J6, and J9 are the ones the old row UI could not honestly test,
the launch pill now *states* the plan, so a pixel probe on the pill region can
double-check what the marker content proves.

## Accessibility pass (manual, per release)

- VoiceOver: summon, arrow the strip (tiles announce name, agent, mode,
  pinned, shortcut), rotor actions switch agent and mode, the confirm banner
  announces itself.
- Full Keyboard Access: ⇥ traverses instead of cycling (KeyPolicy), all pill
  controls reachable.
- System text size at AX5: Settings and onboarding reflow, palette caps at
  xxLarge by design.
- Reduce Motion: no stagger, no springs. Reduce Transparency: opaque pieces.

## What stays manual

Light mode eyeballing, actual terminal handoff to all seven adapters (the
adapter matrix is exercised by launching each at least once before a release),
and Sparkle update flow. Everything else above is scriptable.

## Cadence

- Full journey suite: before every release, from `Scripts/uitest.sh` once the
  journeys land there.
- J1, J7, J8 as a smoke trio: after any palette or launch-path change.
