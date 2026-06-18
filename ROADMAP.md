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

- **Notarized release.** `Scripts/package.sh` already signs, notarizes, and staples
  when the env vars are set. Wire up the real Developer ID, ship a notarized DMG,
  and replace the `appcast.xml` template + `SUPublicEDKey` so Sparkle auto-updates
  work. **[needs maintainer accounts]**
- **Homebrew cask.** `brew install --cask sorkila/tap/tintpad`. Trivial once the
  notarized DMG has a stable download URL. Depends on the release above.
  **[needs maintainer accounts]**
- **Demo GIF.** The README has a `TODO` hole where the pitch should be: summon →
  pick → terminal opens, under two seconds. Reviewers want it to show something an
  alias can't, worktree spin-up or a frecency reorder, not `cd && claude`. It
  carries the whole front page.
- **Accessibility: the Tab/VoiceOver fix.** `PaletteView.handle` swallows Tab and
  Shift-Tab to cycle agents, which blocks keyboard and VoiceOver users from moving
  between the field, list, and footer. Intercept Tab only while the search field is
  focused, or rebind agent-cycling. Esc still exits, so it's not a hard trap, but
  it's the first thing a VoiceOver user hits. (a11y #1)
- **Accessibility: Dynamic Type.** Hard-coded font sizes across `PaletteView`,
  `OnboardingView`, and `SettingsView` ignore Larger Text. Move to semantic text
  styles or `@ScaledMetric`, then verify the layout reflows at AX5. (a11y #3)
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

- **Dangerous-confirm VoiceOver announcement + status live region.** Fire an
  `AccessibilityNotification.Announcement` when a skip-permissions launch is pending,
  and mark the status view as a live region so it's spoken. Lower priority now that
  confirm is off by default, but it's a correctness gap. (a11y #2)
- **App contrast over the glass scrim.** Several foregrounds sit below 4.5:1 over
  the blur, dividers, path text, headers, the empty state. Raise opacities and
  honor `accessibilityReduceTransparency`. (a11y #4)
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
