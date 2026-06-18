# Changelog

All notable changes to Tintpad. Format follows [Keep a Changelog](https://keepachangelog.com), this project aims for [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- Light mode (System / Light / Dark), the palette and Settings follow it.
- Marketing site (`web/`) and full OSS repo kit (README, CONTRIBUTING, SECURITY, templates).

### Changed
- **Now fully open source (MIT) + tip jar.** Every functional feature is free, the optional
  Supporter unlock only adds custom accent tints. "Pro" reworded to "Supporter" throughout.
- Command building hardened: all interpolated template values are sanitized (control chars
  stripped) and shell-quoted, AppleScript escaping handles newlines.
- PATH pre-warm moved off the main thread with a timeout.

### Fixed
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
