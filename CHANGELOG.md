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
- Light mode (System / Light / Dark), the palette and Settings follow it.
- Marketing site (`web/`) and full OSS repo kit (README, CONTRIBUTING, SECURITY, templates).

### Changed
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

### Fixed
- **Accessibility: Tab no longer traps keyboard and VoiceOver users** in the search field.
  It passes through to focus traversal whenever VoiceOver or Full Keyboard Access is on,
  and the footer hints are labelled buttons carrying the same actions. (a11y #1)
- **Accessibility: `accessibilityReduceTransparency` is honored**, dropping the blur for a
  fully opaque palette, and foreground contrast was raised across row names, paths, indices,
  section labels, the empty state, dividers and the status line. (a11y #4)
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
