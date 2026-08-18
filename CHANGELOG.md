# Changelog

All notable changes to Tintpad. Format follows [Keep a Changelog](https://keepachangelog.com), this project aims for [Semantic Versioning](https://semver.org).

## [0.3.5] - 2026-08-18

### Changed
- **A permission failure is no longer a dead end.** When a launch fails because
  macOS hasn't granted (or has silently un-granted) Accessibility or Automation,
  the drop now shows a short red line, "Ghostty needs Accessibility, Return
  opens System Settings, Esc cancels", and Return opens the exact pane,
  triggering the system prompt that adds Tintpad to the list on the way. The
  full error text also covers the stale-grant trap, where the toggle shows
  Tintpad enabled but the grant was keyed to a differently signed build and no
  longer applies, the fix being to remove the entry and add it back. Born of a
  live incident where the developer read his own one-line error as "nothing
  happens".
- **A new app icon.** The drop, rendered for real: a glossy black bead with a
  white rim light and a specular you can actually see in the Dock, where the old
  icon was a black hole. Built to the macOS 26 rules, because Tahoe composites a
  Liquid Glass rim onto every icon and expects the standard 824-in-1024 squircle
  grid. The old full-bleed shape made that ring land half on, half off the
  corners and read broken, and the panel behind the ring is now a flat gray 31,
  the value native dark icons use, because any gradient there turns the system's
  quiet edge into a glowing frame. The raw render is checked in at
  `Resources/appicon-raw.jpg`, and the website favicons and GitHub social card
  carry the new mark already.

## [0.3.4] - 2026-08-14

### Fixed
- **Settings is monochrome everywhere now, not just where it said so.** 0.3.2
  replaced the places that named the accent outright, but SwiftUI's controls
  take it from the environment without ever naming it, so a toggle's track, a
  link's ink, and an agent's glyph in the list carried on painting whatever
  colour macOS was set to into a black and white room. The tint is set once at
  the root, which is the version of this that cannot be half done. Links keep
  their affordance the way print gives it, in full-strength ink with a rule
  under them, rather than by turning blue.

## [0.3.3] - 2026-08-14

### Fixed
- **The first repo no longer sits shorn against the edge of the drop.** 0.3.2
  fixed the scroll offset going stale but still asked the strip to *center* the
  first token, and centering the first thing in a row means scrolling past the
  row's own start. The target is worked out against the viewport, the viewport
  is still moving while the drop arrives, and the strip settled a few tens of
  points along with nothing to pull it back, so the leading chip was cut flat.
  The first token is now pinned to the leading edge, which needs no measurement
  and so cannot be misled by a half-built layout.

## [0.3.2] - 2026-08-14

One black world, and a pass over everything the drop left behind.

### Changed
- **There is no theme setting any more.** Light and System selected nothing a
  user could see, because the drop, Settings, and onboarding each pin a dark
  appearance on their own window. The picker is gone, and the app now pins the
  theme early enough that even the "already running" alert arrives in the
  black world instead of flashing white.
- **Onboarding is monochrome**, like everything the drop introduced. The
  orange call to action is now the product's own signature, a white chip with
  black ink, and the step numbers sit back in gray so the titles lead.
- **Settings is monochrome for real.** The pinned-repo marker, the
  default-mode marker, and an agent without a tint of its own were drawing in
  the *system* accent, so whatever color macOS was set to leaked into a room
  the product paints black and white. They are ink and weight now.
- Every message the app says was swept to one voice, sentence case and commas,
  matching the house style the docs and the website already followed.

### Fixed
- **The first repo no longer shears against the edge of the drop.** Typing
  reshapes the row but left the scroll view holding its old offset, and
  because a query change already resets the selection to the first repo, the
  observer that would have re-anchored it never fired. The row settled
  scrolled, and the leading chip's curve was cut flat by the viewport.
- **The strip's left edge now fades only when it is actually hiding
  something.** At rest that edge is margin, not overflow, so fading it was a
  lie about where the row begins.

### Removed
- The accent is fully retired. It had already left the drop, and it now
  leaves onboarding, the model, and the copy that still promised it.
- Six unreachable monetization gates. They dated from a Pro tier that never
  shipped, they could never fire under the tip-jar model, and two of them sat
  on the path that launches a permission-skipping mode. `ProFeature` is now
  the single cosmetic thing a tip unlocks, and the check that reads it is
  exhaustive, so a future gate cannot be added without a deliberate decision.

## [0.3.1] - 2026-08-10

### Fixed
- **Launched agents always start fresh, top-level sessions.** If the terminal
  (or Tintpad itself) was started from inside a Claude Code session, its
  environment carries session markers like `CLAUDE_CODE_CHILD_SESSION`, and a
  `claude` launched there thinks it's a subagent and silently stops saving
  transcripts, so the session never shows up in resume. Tintpad now scrubs
  these inherited markers from its own spawn environment and prefixes every
  launched command with `env -u`, which fixes even a polluted terminal it
  doesn't own. Deliberate configuration (`ANTHROPIC_API_KEY`,
  `CLAUDE_CONFIG_DIR`) is never touched.

## [0.3.0] - 2026-08-05

The drop: the palette redesigned from scratch, again, and this time it fell
out of the notch.

### The drop
- **The palette is now a black capsule that falls out of the camera housing.**
  Summon, and a bead drips from the notch's lip, falls, and splats into a
  hanging capsule holding your repos, settling with one soft bob, springs all
  the way down. Launch runs the film backwards. Reduce Motion gets a
  crossfade. Macs without a notch get the identical drop as a floating pill
  below the menu bar.
- **Stark black and white.** Repo names in gray, the selected repo a white
  chip with black ink, and nothing else, the repo hues retired from the
  palette (they live on in Settings and the Supporter tint perk). Danger red
  is the only color the drop allows: the MODE chip and the confirm line.
- **The contract is two instrument chips.** AGENT and MODE as etched hairline
  capsules with micro-label eyebrows, always present, quietly clickable, real
  flags in the tooltips, and never truncated. The mode that skips permissions
  is a red-etched chip.
- **Fully mute at rest.** The drop holds only the tokens. The query
  materializes at the left as you type, with a live match count.
- **Settings matches the drop**: SF Pro throughout (mono survives only for
  machine values like paths and flags), forced dark, monochrome sidebar and
  controls. One scheme across the product.
- The website redesigned around the drop, and the demo re-scripted to show
  the fall, the filter, and the chips.

### Developer
- The Liquid Glass call sites and their compiler gates are gone with the
  glass itself, the drop is plain black and builds on every toolchain.

## [0.2.0] - 2026-07-28

The 2.0 pass: the palette rebuilt around one idea, the app hardened by a
three-way engineering audit, and the launch flow taught to remember.

### The palette: ⌘Tab for repos
- **A floating Liquid Glass cluster, not a sheet.** Three discrete glass pieces
  with real gaps: a search pill (`tintpad ❯`), a horizontal strip of repo tiles
  you arrow through like the app switcher, and a launch pill that names the
  contract. On macOS 26 each piece is real `glassEffect` in a shared
  `GlassEffectContainer` (interactive pills, vibrancy-based legibility over a
  whisper of frost); macOS 14/15 keep a vibrancy-stack fallback.
- **Every repo gets its tint.** A stable hue hashed from the repo's name (the
  danger-red band is reserved), its short name in that hue (`KUTA`, `SB3K`,
  `TPL`), pinned repos first. Recognition works the way ⌘Tab works: color plus
  letters, at a glance. Selection scales up on a spring and glows in its hue.
- **The launch pill is the contract**: `❯ agent · mode` plus the repo's path
  and `⑂ branch*` (dirty-checked in the background, cached per summon, never
  blocking). The agent and mode words are quietly clickable, with the real
  flags in the tooltip, and the caret turns red the moment ↵ would skip
  permissions.
- **One voice of type**: SF Mono at exactly two sizes, weight as hierarchy.
  Settings and onboarding share the rule (mono speaks labels and identity, SF
  Pro speaks prose), with a monochrome sidebar and the accent only on "here".
- The panel window is borderless and draws no system shadow, which fixes the
  square ghost band macOS 26 drew behind rounded glass. Pieces carry their own
  shadows.
- **Motion that means something.** On summon the three pieces spring apart from
  one blended glass body (the container's blend distance sits just under the
  resting gap, so they fuse only in transit). ↵ plays a 160ms launch gesture,
  the selected tile pulses as the cluster releases downward, and worktree and
  prompt modes crossfade instead of hard-cutting. All transform-only, all
  skipped under Reduce Motion (which also closes instantly, because a delay
  with no animation is just lag).
- **A real icon.** The app icon and menu-bar glyph are now drawn from the
  product's own grammar (a dark tile, the brand caret, a block cursor: a
  prompt, waiting), generated reproducibly by `Scripts/make-icon.swift`. The
  menu-bar glyph is a proper template image that follows the system
  appearance instead of a hard-orange sticker.

### Launch flow
- **Repos remember how you opened them last.** Every launch stamps the repo's
  agent and mode, and plain ↵ repeats it. An explicit per-repo default pinned
  in Settings still wins (and the Settings agent picker no longer wipes that
  pin when re-selecting the same agent, the bug that started this release).
- **⌘0 resumes the last session exactly**, from the palette or the global
  hotkey, and the hint only appears when the session can still be
  reconstructed. Failures say the true thing ("isn't on your PATH" is not
  "that repo is gone").
- **One danger gate for every path.** Launch, dispatch, prompt, worktree, and
  resume all arm the same confirm banner when a mode skips permissions, and a
  pending confirm is cancelled (never fired) by clicking another tile, ⌘n, or
  ⌘0. A dangerous last session triggered from the global hotkey routes through
  the palette so the confirm has a surface.
- Worktree creation runs off the main thread with a status line, and clones
  from GitHub are fully async: the UI can no longer freeze on git.

### Hardening (from a three-pass engineering audit, see docs/AUDIT.md)
- A corrupt `store.json` is preserved as `store.corrupt-<ts>.json` instead of
  being silently reseeded and overwritten (repos, sessions, and the Supporter
  key survive), and save failures are no longer swallowed.
- A single-instance flock guard stops a second copy (say a dev build) from
  silently clobbering the first one's data.
- `ProcessRunner` gives every subprocess a hard timeout, concurrently drained
  pipes, and SIGTERM-then-SIGKILL. Ghostty re-checks it is frontmost before
  typing a command, Terminal's tab path pre-checks Accessibility, Warp's URL
  is built with `URLComponents`, and worktree branch names are pinned so a
  dash-leading name can't become a git option.
- Frecency clamps future-dated timestamps (clock rollback can't pin a repo to
  the top), Settings writes are debounced and flushed on quit, dispatch log
  names are collision-free, and the command template's space cleanup no longer
  rewrites double spaces inside quoted paths and prompts.

### Accessibility
- Dynamic Type across Settings and onboarding: semantic text styles with every
  paired container on a matching `@ScaledMetric`. The palette caps at xxLarge
  by design (a fixed-width HUD).
- Contrast measured, not eyeballed: onboarding's button went from 2.7:1 to
  6.6:1, meaningful text left tertiary, and the palette's quietest inks clear
  4.5:1. Tab stays free for focus traversal under VoiceOver and Full Keyboard
  Access, tiles expose rotor actions for switching agent and mode, and Reduce
  Motion and Reduce Transparency are honored everywhere.

### Developer
- 45 pure-logic unit tests (launch precedence, git dirty detection, repo
  tints, injection surface, frecency edge cases). `docs/TESTING.md` is the
  journey-based synthetic user testing plan. `TINTPAD_SHOWCASE=1` and
  `TINTPAD_SHOWCASE_SETTINGS=1` drive screenshot harnesses.

## [0.1.0], unreleased (dev)
- Initial build: global hotkey → palette → frecency repo search → agent + run mode →
  terminal handoff (7 terminals), worktrees, headless dispatch, prompt library, per-repo
  presets, GitHub import, open-in-editor.
