# Changelog

All notable changes to Tintpad. Format follows [Keep a Changelog](https://keepachangelog.com), this project aims for [Semantic Versioning](https://semver.org).

## [0.4.1] - Unreleased

### Added
- **Hold ⌘ and the drop shows its keys.** After a short beat each of the first
  nine repos wears the digit that launches it, and each contract chip names its
  key: ⇥ on AGENT, ⇧⇥ on MODE, P on a starting prompt, ⏎ on OPEN IN. Let go and
  the drop is mute again. A quick chord like ⌘R flashes nothing, the summon
  hotkey's own ⌘ never reveals, and the capsule keeps its width, since the hug
  measures the drop at rest.
- **Palette keys in the menu bar.** A new menu under "Summon palette" lists every
  key the palette answers to, row for row with the README's Keys table, which
  now also carries a Settings row (⌘,).
- **Search is fuzzy, and shows what it found.** "tp" finds tintpad, "dl" finds
  demand-ledger, and "cafe" finds Café. Results rank by how well they match
  first (exact name, prefix, word starts, a fragment, letters in order, then
  the path) and
  by frecency inside each tier, so typing "tint" puts tint ahead of a
  mytintfork you open daily. The matched letters read white and semibold on the
  gray tokens. On the white chip they stay full black and bold while the rest
  of the name steps back, never a color.

### Changed
- **A search that finds nothing says what to try.** The line reads "No match
  for “zzq”, ⌘R rescans your folders", since a repo cloned since the last scan
  is the usual reason.

## [0.4.0] - Unreleased

### Added
- **Onboarding starts with your repos.** The first step scans your folders and
  says what it found ("Found 14 repos in ~/Developer"), and "Add a folder…" adds
  the one your projects live in and scans it on the spot. First run used to end
  with an empty drop whenever the default folders did not match yours.

### Changed
- **The hotkey is the last thing onboarding asks for.** Terminal choice and the
  test launch are now one step, the hotkey comes after them, and the finish
  button names your summon hotkey, so the key you need next is the last one
  you saw.
- **Settings puts each thing where you look for it.** GitHub import sits under
  Workspace next to Repos, and the frecency half-life moved from Appearance to a
  Ranking card on Repos, beside the list it orders. The confirm toggle left the
  Advanced group for its own Safety section on General, with a line saying which
  paths it covers. A repo's agent and mode pickers read "Remembers last" instead
  of a dash and "default", and Scan says "Scanned, 3 new repos" and clears.
- **Notifications are requested on your first ⌃⏎.** Tintpad used to ask at app
  launch, before anything had a reason to notify you. It now asks the first time
  a headless dispatch will want to report back.
- **New installs confirm before skipping permissions.** "Confirm before launching
  a mode that skips permissions" is on for a new store. An existing install keeps
  its setting, whether it was saved off or never saved at all.
- **The drop sits closer and matches the housing.** The capsule now hangs 8pt
  below the camera housing instead of 34pt, and on a notched Mac it is exactly as
  tall as the housing is deep (between 32 and 40 points), so the two read as one
  shape. Without a notch the pill is 36pt tall and sits 8pt under the menu bar. A
  faint one-pixel key line holds the capsule's edge against dark walls, and the
  heavy floating shadow gave way to a light contact shadow. The contract's
  eyebrows are a touch larger and brighter (8.5pt), so AGENT and MODE are
  readable at a glance. Every size now comes from one tested geometry, and the
  window's transparent margin shrank to match the smaller shadow.
- **The drop forms in place, and leaves the way it came.** A 12pt bead swells at
  the housing's lip, expands in place into the capsule at 70ms, and the words
  follow the shape at 170ms and 200ms, rising out of a soft blur, so the drop is
  readable in about 0.4 seconds. Return and Esc shrink the capsule back into the
  bead and the housing absorbs it (Esc a touch quicker), and a click elsewhere
  just fades it. Reduce Motion gets a short crossfade both ways. The old fall and
  bob were three nested timers that could not be interrupted, so pressing the
  hotkey during an arrival could stack two animations. Now every step belongs to
  one cancellable timeline, a summon during an exit brings the drop straight
  back, and the panel is never removed before its exit has played.
- **One white chip slides between repos, and the row holds still.** The selected
  repo used to grow its own padding, so every arrow press nudged its neighbours.
  Tokens now keep one padding and one spacing, and a single chip slides to the
  next repo with the strip scrolling on the same curve. The selected name is set
  in medium rather than semibold. Leaving, the words fade and blur in place
  instead of sinking.
- **The capsule hugs its content.** A short list gives a short drop, never
  narrower than the housing plus a capsule height either side (280pt on a display
  without a notch) and never wider than before, in 8pt steps so a keystroke does
  not nudge it. While you type, or while a confirm or capture line shows, it only
  grows, so it never pulls in under the caret or breathes at the gate, and an
  empty field back on the repos lets it settle. Holding a modifier changes the
  chips, never the capsule.
- **Every line in the drop keeps its subject.** The confirm, Opening, error, note,
  worktree and prompt lines now show the repo they are about as a white chip to
  their left, including a session resumed with ⌘0 from a different repo.

### Fixed
- **Larger text sizes no longer grow the drop past its cap.** Dynamic Type was
  clamped inside the drop, where its own size metrics could not see the clamp,
  so the capsule and its window could outgrow the extra-extra-large limit.

## [0.3.8] - Unreleased

### Added
- **The contract chips read what Return would do while you hold a modifier.**
  Holding ⌥ turns MODE red before Return lands, ⇧ shows the safest mode, ⌃ adds
  RUN · Headless, and holding ⌘ for a beat adds OPEN IN with your editor. Let go
  and the chips return to rest. The modifiers used to change a launch without
  the drop saying so, so a leftover ⌥ could skip permissions under a gray chip.
  The preview and the launch now share one rule, so they cannot disagree.

### Fixed
- **The drop's shadow really no longer lingers after it is dismissed.** Removing
  the window's fade in 0.3.7 was not enough, the shadow could still be left on
  the desktop. Three things kept a frame alive. The panel was ordered out while
  it still held a drawn capsule, the dismissal on a click elsewhere ran inside
  AppKit's own deactivation pass, and a launch reinflated the capsule offscreen
  just before closing. Dismissal is now one sequence. The panel turns fully
  transparent and the drop snaps back to rest, it is ordered out on the next
  runloop turn, and focus returns to the previous app on the turn after that, so
  any frame the window server keeps is empty. A click elsewhere starts that
  sequence a turn later, outside the deactivation pass, and summoning the drop
  while it is being dismissed cancels the dismissal, so pressing the hotkey twice
  fast brings it back instead of leaving it hidden.
- **Return can no longer launch twice.** A Return pressed again while a launch
  was starting, or while the drop was closing after one, could open a second
  terminal. Every launch gesture (Return, a click on a repo, ⌘1 to ⌘9, ⌘0) now
  passes one gate that ignores it while a launch is underway.
- **Return on a Warp note closes the drop instead of launching again.** Warp
  leaves the command on the clipboard and the drop stays open to say so, and a
  second Return there used to open another Warp window. It now closes the drop,
  and the note closes by itself after 1.6 seconds.

### Changed
- **The confirm line names the repo.** It reads "Skip permissions in tintpad
  with Claude Code, Return confirms, Esc cancels", so the launch you are
  consenting to says where it runs, not only how.
- **The drop says where a launch is going.** "Opening Ghostty…" (or your editor)
  is painted before the handoff starts, so a slow terminal no longer looks like
  a Return that did nothing. The Warp note now reads "Command copied, paste it
  in Warp".

## [0.3.7] - 2026-08-30

### Fixed
- **The drop's shadow no longer lingers after it is dismissed.** The panel
  carried AppKit's utility-window animation, which fades a window out rather
  than removing it, so the order-out returned while the drop was still on
  screen and the app was hidden in the same breath. AppKit was then asked to
  hide a window it still believed was visible, and the frame it captured could
  be left composited behind us. Against the black camera housing the capsule
  itself is invisible, so the part that survived on the desktop was its shadow.
  The window now carries no AppKit animation at all, the drop scripts its own
  arrival and exit, and focus returns to the previous app one runloop turn
  later, once the removal has reached the window server.

## [0.3.6] - 2026-08-24

### Fixed
- **Ghostty no longer opens a blank extra window on the day's first launch.**
  Activating Ghostty when it isn't running also starts it, and Ghostty opens
  its own initial window on start, so the unconditional ⌘N that followed left
  two windows, one blank at home and one correct in the repo. A cold start now
  types the command into the window the launch itself produces, polling for
  the process and its window instead of trusting a fixed delay, and ⌘N
  survives only as a fallback for configs that suppress the initial window. A
  running Ghostty behaves exactly as before.

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
