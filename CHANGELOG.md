# Changelog

All notable changes to Tintpad. Format follows [Keep a Changelog](https://keepachangelog.com), this project aims for [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- **Palette rebuilt as a reduced terminal HUD.** Monospace on a strict 8pt grid. The accent
  now means one thing ("here, now") and danger red means one thing ("skips permissions"),
  with no third colour. Selection is a precise marker plus a neutral lift rather than a
  saturated bar, and it turns red when the selected row would skip permissions.
- **⌘1–⌘9 jump to a numbered row and launch it.** The numbers shown beside each repo are
  this shortcut, so they are no longer decoration.
- **The panel sizes itself to its content**, pinned at the top edge so the search field
  never shifts under the cursor while you type.
- **Monograms for agents without a brand mark.** Assigned across the whole agent set so
  they stay distinct from each other, so a third agent no longer falls back to a generic
  terminal glyph.
- **Repos remember how you opened them last.** Every launch stamps the repo with its
  agent and run mode, and the palette offers that pair next time. An explicit per-repo
  default pinned in Settings still wins over the remembered launch.
- **The palette knows your working tree.** The selected repo's branch now carries the
  shell-prompt dirty marker (`main*`) when there are uncommitted changes. The check
  runs off the main thread with a hard timeout and a per-summon cache, so the palette
  never blocks on git, and an unknown answer renders as nothing rather than a guess.
- **⌘0 resumes the last session** from inside the palette — repo, agent, mode, and
  prompt replayed exactly, the same semantics as the global resume hotkey. The hint
  only appears once a session exists.
- Light mode (System / Light / Dark), the palette and Settings follow it.
- Marketing site (`web/`) and full OSS repo kit (README, CONTRIBUTING, SECURITY, templates).

### Changed
- **The palette is now a floating Liquid Glass cluster — ⌘Tab for repos.** Not a sheet
  with rows: three discrete glass pieces with real gaps. A search pill (`tintpad ❯`), a
  horizontal strip of repo tiles you arrow through like the app switcher (agent mark
  large, name beneath, pinned first, dangerous tiles ringed red before you arrive), and
  a launch pill that names the contract: `❯ agent · mode` with the path and branch* at
  the right, agent/mode quietly clickable with the real flags in the tooltip. The
  window draws no system shadow (AppKit shadows the rectangular frame, which read as a
  ghost box behind rounded glass) — each piece carries its own, inside a transparent
  margin. ←/→ move through the strip when the field is empty; ↑/↓, ⌘1–⌘9, ⌘0, ⇥/⇧⇥ all
  unchanged. Detail pass: tiles are lit (top-down gradient, hairline edge) rather than
  flat, the selected tile scales up on a spring and glows in its tint, hover has its
  own quieter lift, and the launch caret turns red the moment ⏎ would skip permissions.
  All micro-motion is transform-only (never layout) and honors Reduce Motion. Type
  speaks in exactly one voice at exactly two sizes: SF Mono at 15 for the field, 12 for
  everything else, with weight carrying the hierarchy — no more SF Pro / SF Mono mixing
  across six sizes. Coherence pass: one left grid line runs through all three pieces,
  the two pills share one height, tiles fade at the strip's edges instead of clipping,
  the path dims its directory and brightens the repo name, and the text caret wears the
  brand tint. Settings and onboarding joined the family under one rule — mono speaks
  labels and identity (sidebar, pane titles, section headers, step titles), SF Pro
  speaks prose.
- **Every repo gets its tint.** Tiles now carry the repo's identity, not the agent's: a
  stable hue hashed from the repo name (never landing in the danger-red band), the
  repo's monogram in that hue, and the agent mark as a small corner badge. Recognition
  works the way ⌘Tab works — color plus letter, at a glance — and the app's name
  finally means something visible. The selected tile rings in primary and glows in its
  own hue; danger red still overrides the ring.
- **Native material pass, researched against Liquid Glass guidance.** Legibility now
  comes from vibrancy (hierarchical foreground styles on the glass) instead of flat
  opacities over a heavy scrim — the frost dropped to a whisper and the muddiness went
  with it. The pills are interactive glass (they respond to hover/press like system
  controls), the strip's corner radius is concentric with its tiles, shadows are
  weighted by prominence, and the three pieces arrive with a 50ms stagger on summon
  (transform-only, Reduce Motion honored).
- Earlier in this cycle the palette was a Liquid Glass card list (superseded by the
  cluster above): On macOS 26
  the panel surface is the real system material (`glassEffect`, Tahoe-scale continuous
  corners, a measured frost so 11pt mono survives a busy window); earlier systems keep
  the vibrancy stack. Nothing shifts underfoot: rows are equal height, selection moves
  instantly like Spotlight, and the launch plan has one fixed home — the footer shows
  the exact command ⏎ will run, plus the agent and run mode as real clickable chips
  (the visible counterpart of ⇥/⇧⇥, also VoiceOver rotor actions) and the git branch.
  Rows are just mark + name, and the launch plan is one line in prompt grammar —
  `❯ agent · mode` with the branch at the right — whose agent and mode are quietly
  clickable (real flags in the tooltip). Prompts top and bottom are the identity:
  Tintpad reads as a prompt that hands off to your terminal, not a launcher with
  accessory chrome. ⌘1–⌘9 and ⌘0 still work; ⌘0 resume is taught in the idle corner of
  the search line. Type speaks in two voices: SF Pro for the interface, SF Mono only
  where mono means something. Selection is a soft accent-tinted fill that turns
  danger-red when the selected mode skips permissions. The panel window is borderless
  now — on macOS 26 a titled panel's reserved titlebar strip drew system glass chrome
  as a square-cornered band behind the rounded card.
- **Now fully open source (MIT) + tip jar.** Every functional feature is free, the optional
  Supporter unlock only adds custom accent tints. "Pro" reworded to "Supporter" throughout.
- Command building hardened: all interpolated template values are sanitized (control chars
  stripped) and shell-quoted, AppleScript escaping handles newlines.
- PATH pre-warm moved off the main thread with a timeout.
- Repeated ink removed from the palette: a repo's path now appears only on the row you are
  about to launch, instead of on every row.
- Agent marks render at the exact pixel size they are drawn, instead of being pre-rendered
  at one size and rescaled a second time by SwiftUI, and each brand carries an optical
  correction so an airy mark and a dense one read as the same weight.
- **Settings and onboarding follow the palette's design language.** The nine multicolor
  gradient sidebar tiles are gone: monochrome glyphs, with the brand accent appearing only
  on the selected row's glyph, the same "here, now" rule the palette follows. Section
  labels use the palette's monospace voice, the pane header dropped its decorative icon
  tile, and onboarding's step bubbles became monospace accent indices (01, 02, 03).

### Fixed
- **Per-repo default mode no longer disappears.** Touching the agent picker in
  Settings → Repos wiped the repo's pinned run mode even when the agent did not change,
  so a repo pinned to YOLO silently fell back to the agent default. The pin is now
  cleared only on a real agent change.
- **Accessibility: Tab no longer traps keyboard and VoiceOver users** in the search field.
  It passes through to focus traversal whenever VoiceOver or Full Keyboard Access is on,
  and the footer hints are labelled buttons carrying the same actions. (a11y #1)
- **Accessibility: `accessibilityReduceTransparency` is honored**, dropping the blur for a
  fully opaque palette, and foreground contrast was raised across row names, paths, indices,
  section labels, the empty state, dividers and the status line. (a11y #4)
- **Accessibility: Settings and onboarding follow Dynamic Type.** All hard-coded point
  sizes on the resizable surfaces moved to semantic text styles, and every container
  paired with scaling text (sidebar and header icon tiles, onboarding step circles,
  slider value chips, tint swatches, symbol previews) scales with it via `@ScaledMetric`,
  so glyphs stop outgrowing their boxes at accessibility sizes. (a11y #3)
- **Accessibility: onboarding contrast measured and fixed.** The "Get started" button was
  white on the orange accent at 2.7:1, now black on accent at 6.6:1, and empty-state
  subtitles moved from tertiary to secondary so instructional text clears 4.5:1. (a11y #4)
- The palette no longer clips its last row. A `.titled` panel reserves a titlebar strip, so
  the window frame has always been about 32pt taller than the visible glass, and the panel
  was being handed that much less than it asked for.
- First summon after launch is responsive (key monitor installed eagerly).
- Mode chip and low-contrast text are legible in light mode.
- About box shows the real bundle version instead of a hard-coded placeholder.
- "Buy me a coffee" button uses the brand accent (was a third-party yellow).
- Dispatch no longer leaks a file handle if the background process fails to start.

### Security
- Added tests for the AppleScript escaping layer and for `{branch}`/`{remote}` quoting,
  covering the injection surface end to end (shell single-quoting then AppleScript escaping).

## [0.1.0], unreleased (dev)
- Initial build: global hotkey → palette → frecency repo search → agent + run mode →
  terminal handoff (7 terminals), worktrees, headless dispatch, prompt library, per-repo
  presets, GitHub import, open-in-editor.
