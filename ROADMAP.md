# Roadmap

Where Tintpad is going. This is intent, not a contract, order shifts as reality
does. Items tagged **[needs maintainer accounts]** are blocked on credentials only
Erik can supply (Apple Developer, signing/notarization, Buy Me a Coffee, the
hosting that serves `appcast.xml`), so a PR alone can't land them.

Tintpad is free and MIT, local-only, no accounts, no telemetry. None of that
changes. The tip jar stays a tip jar.

## Near-term

The gap between "runs from source" and "someone who isn't a Swift dev can install
it." That's the whole job right now.

- **Notarized release.** ✅ Done through v0.2.0: signed, notarized, stapled,
  Sparkle appcast live at tintpad.com/appcast.xml, auto-updates working.
- **Homebrew cask.** ✅ Done, `brew install --cask sorkila/tap/tintpad` serves 0.2.0.
- **Demo.** ✅ Done, and it records itself now: the `TINTPAD_DEMO` harness plays a
  scripted sequence and `docs/DEMO.md` is the one-command recipe. Current assets are
  1x (shot on an external display), re-run on the built-in retina for 2x.
- **Accessibility: the Tab/VoiceOver fix.** ✅ Done. Tab passes through to focus
  traversal whenever VoiceOver or Full Keyboard Access is on (`KeyPolicy`), and the
  footer's "agent" and "mode" hints are real labelled buttons carrying the same
  actions. Ordinary keyboard use keeps ⇥ as the agent shortcut. (a11y #1)
- **Accessibility: Dynamic Type.** `PaletteView` is done: its type and grid metrics
  scale together via `@ScaledMetric`, which they must, because the panel's computed
  height is derived from those metrics. Onboarding and the Settings panes are done
  too: their hard-coded sizes moved to semantic text styles, with every paired
  container (icon tiles, step circles, value chips, symbol previews) on a matching
  `@ScaledMetric` so nothing outgrows its box. Remaining: an eyes-on sweep at AX5
  to confirm the reflow. (a11y #3)
- **More terminal adapters.** Seven today (Ghostty, iTerm2, kitty, WezTerm,
  Alacritty, Terminal, Warp). Each new one is a protocol and a struct, the most
  PR-friendly surface in the repo. Wanted: tmux/zellij sessions, Hyper, Tabby,
  Rio, WindowsTerminal-on-ARM-VM types if anyone cares. See
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
- **Raycast funnel.** A script command already lives in [`raycast/`](raycast/) and
  drives the `tintpad://` scheme. Next: publish it to the Raycast store so it shows
  up where the launcher crowd already is. A real TypeScript extension (search repos,
  recents, project actions) is a later, bigger thing. **[needs maintainer accounts]**

## Mid

- **Dangerous-confirm VoiceOver announcement + status live region.** ✅ Done.
  `PaletteView` announces both status changes and a pending skip-permissions launch.
  (a11y #2)
- **App contrast.** Mostly done. Settings and onboarding had their pass (onboarding's
  custom pairs computed against WCAG, the prominent button went from 2.7:1
  white-on-accent to 6.6:1 black-on-accent, meaningful text no longer uses tertiary),
  and the palette's quietest inks were raised to compute 4.5:1+ against its scrim.
  Reduce Transparency drops the blur for a fully opaque card. Remaining: a worst-case
  desktop spot-check of the glass card with a real checker. (a11y #4)
- **Design tokens.** A real type ramp, spacing scale, and white-alpha system instead
  of scattered literals, plus a terminology sweep so the same thing has one name.
- **Full launch-path tests.** `Launcher` dependency injection so the summon →
  resolve → handoff path can be tested end to end, not just the pure logic.
- **Raycast extension (full).** TypeScript: fuzzy repo search, recents, per-project
  actions, Tintpad's frecency model surfaced inside Raycast for people who live
  there. The script command is the bridge, this is the bridge made of stone.

## Later

Wishlist. No promises, no dates.

- **Editor adapters beyond the current set**, same plug-in shape as terminals.
- **Sessions / multiplexer awareness**, reattach to an existing tmux/zellij session
  instead of always opening a fresh window.
- **Smarter repo discovery**, respect workspace files, monorepo subprojects, and
  ignore rules without making the user babysit a list.
- **Linux**, the dispatch and adapter model isn't Mac-specific in spirit, but the
  hotkey, menu-bar, and AppleScript layers are. Big lift, only if there's pull.
- **Localization**, once Dynamic Type and the string sweep land, strings are
  already extractable. Translations welcome.

---

Found a sharp edge or want to own one of these? PRs welcome, terminal adapters
especially. [`CONTRIBUTING.md`](CONTRIBUTING.md) has the lay of the land. If
Tintpad earns a spot in your day, the tip jar is at
[buymeacoffee.com/eriknielsen](https://www.buymeacoffee.com/eriknielsen).
