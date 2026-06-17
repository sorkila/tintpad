# Changelog

All notable changes to Tintpad. Format follows [Keep a Changelog](https://keepachangelog.com);
this project aims for [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- Light mode (System / Light / Dark); the palette and Settings follow it.
- Marketing site (`web/`) and full OSS repo kit (README, CONTRIBUTING, SECURITY, templates).

### Changed
- **Now fully open source (MIT) + tip jar.** Every functional feature is free; the optional
  Supporter unlock only adds custom accent tints. "Pro" reworded to "Supporter" throughout.
- Command building hardened: all interpolated template values are sanitized (control chars
  stripped) and shell-quoted; AppleScript escaping handles newlines.
- PATH pre-warm moved off the main thread with a timeout.

### Fixed
- First summon after launch is responsive (key monitor installed eagerly).
- Mode chip and low-contrast text are legible in light mode.

## [0.1.0] — unreleased (dev)
- Initial build: global hotkey → palette → frecency repo search → agent + run mode →
  terminal handoff (7 terminals), worktrees, headless dispatch, prompt library, per-repo
  presets, GitHub import, open-in-editor.
