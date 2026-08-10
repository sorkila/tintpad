# CLAUDE.md

Guidance for Claude Code (and contributors) working in this repo.

## What this is
**Tintpad**, a native macOS (Swift/SwiftUI) menu-bar launcher. Global hotkey →
floating palette → fuzzy-find a repo (frecency-ranked) → pick agent + run mode →
your terminal opens at that repo with the agent (Claude Code, Codex, …) running.
Hands off to *your* terminal, it isn't one. Accessory app (`LSUIElement`), local-only,
no accounts. **Free & open source (MIT) + optional Supporter tip.**

## Status (shipped)
**v0.3.0 "the drop" is live** (2026-08-05): full design pivot — the palette is a black
capsule that falls out of the notch (see Palette design rules), Settings matches it
(SF Pro, forced dark, monochrome), website + demo film + app icon + GitHub social card
all redesigned around it. The Supporter perk is now tinted chips. Same release train
as before: bump `Resources/Info.plist` (BOTH CFBundleShortVersionString and
CFBundleVersion — Sparkle compares the build number) then `./Scripts/release.sh`.
**v0.2.0** (2026-07-28): the 2.0 pass — Liquid Glass ⌘Tab palette, launch
memory, agent-vocabulary modes, three-audit hardening. Notarized DMG at
`github.com/sorkila/tintpad/releases/tag/v0.2.0`,
direct download via `releases/latest/download/Tintpad.dmg`, site live at tintpad.com,
Homebrew tap at `sorkila/homebrew-tap` (`brew install --cask sorkila/tap/tintpad`),
Sparkle auto-update wired (`web/appcast.xml` → tintpad.com/appcast.xml). Bump the version
in `Resources/Info.plist` then run `./Scripts/release.sh` to cut the next one.

## Commands
```sh
swift build              # debug build
swift test               # 50 unit tests (pure logic, keep green)
swift run                # run from source (dev; unsigned)
./Scripts/package.sh     # assemble + sign .app/DMG in a TMPDIR scratch (signs if SIGN_IDENTITY set)
./Scripts/dev-install.sh # build → Developer ID sign → install to /Applications (local dev)
./Scripts/release.sh     # one-command notarized release (needs SIGN_IDENTITY + NOTARY_PROFILE)
./Scripts/sign-license.swift <email>  # sign a Supporter key (manual tint fulfillment)
./Scripts/uitest.sh      # synthetic-input GUI smoke test (needs Accessibility/Automation)
./Scripts/record-demo.sh # self-recording demo film: seeds portfolio repos, records the
                         # scripted take, cuts demo.mp4/poster/og/hero, restores the store
```
Swift 6, macOS 14+. Deps (SPM): KeyboardShortcuts, Sparkle.

## Architecture (see docs/ARCHITECTURE.md for detail)
- **Models.swift / Store.swift**, Codable model + `AppStore` (@MainActor), JSON at
  `~/Library/Application Support/Tintpad/store.json`. Tolerant decoders (adding a field never reseeds).
- **PaletteView.swift / CommandPanel.swift**, the palette (NSPanel + SwiftUI) and its controller.
- **TerminalAdapter.swift**, 7 terminal adapters. **CommandTemplate.swift**, command building (the injection surface).
- **LaunchService.swift**, `makeLaunch` (pure, tested) + injectable `resolveTerminal`.
  `LaunchDefaults` (Models.swift) is the launch precedence: override → pin → last-used → default.
- **ProcessRunner.swift**, the one way subprocesses run (timeout, drained pipes,
  SIGTERM→SIGKILL). **GitStatus.swift**, bounded dirty check. **RepoTint.swift**, per-repo
  hue + short name. **SingleInstance.swift**, flock guard.
- **ShellEnvironment.swift**, login-shell PATH resolution. **Frecency.swift**, ranking.
- **SettingsView.swift** (+ per-pane views), **OnboardingView.swift**, **LicenseManager.swift**, **Tokens.swift**.

## Conventions
- All command building goes through `CommandTemplate`, every interpolated value is
  sanitized (control chars stripped) and POSIX single-quoted. Never hand-build shell or AppleScript strings.
- **Launches are always fresh top-level sessions.** Inherited agent session markers
  (`ShellEnvironment.sessionMarkers`, e.g. `CLAUDE_CODE_CHILD_SESSION`, which silently
  disables Claude Code transcript saving) are scrubbed twice: from Tintpad's own spawn
  env (`processEnvironment`) and via an `env -u` prefix on the launched command
  (`CommandTemplate.inFreshSession`), which is the only fix that reaches a shell owned
  by a dirty terminal. `env -u`, never `unset …;` — a `;` splits the adapters'
  `cd … && cmd` chain. Session-instance markers only, never deliberate config
  (`ANTHROPIC_API_KEY`, `CLAUDE_CONFIG_DIR`).
- **Voice**: SF Pro speaks the product, mono speaks only machine values (paths, flags,
  keys) via `Font.mono`/`Font.monoStyle`. Resizable surfaces (Settings, onboarding) use
  the scalable `TypeRamp` (Dynamic Type), the drop uses its own `@ScaledMetric` point
  sizes clamped to xxLarge.
- **Agent marks** (`AgentMarks.swift`). A brand mark where artwork exists, a `Monogram`
  everywhere else, so a third agent never falls back to a generic glyph. Monograms are
  assigned across the **whole agent set** (`AppStore.monogram(for:)`, the single source of
  truth) so they stay distinct, one letter until two collide. Marks are rasterized on
  demand at the exact pixel size they will be drawn, since pre-rendering at one size and
  letting SwiftUI rescale resamples twice and arrives soft. Each brand carries an
  `optical` correction because icons in a set must match in **ink, not bounding box**
  (Claude's airy radial needs to be drawn larger and held brighter than Codex's dense blob).
- **Palette design rules** (`PaletteView`, documented on the type). The palette is
  **the drop**: a pure-black capsule that falls out of the notch (a bead drips from the
  housing's lip, falls 22pt, splats into the capsule, settles with one bob — springs
  throughout, Reduce Motion gets a crossfade). Displays without a notch get the same
  drop as a floating pill below the menu bar. **Black and white only**: repo names in
  gray, the selected repo a white chip with black ink, the caret white, forced dark
  world in every theme (`environment(\.colorScheme, .dark)` + darkAqua on the panel and
  Settings windows). Danger red is the only color, spent on the MODE chip and the
  confirm line, said once passively and once at the gate. **One object language**:
  every element is a capsule of `chipH` — white chip (position), etched hairline chips
  (the contract: AGENT and MODE as labeled instrument fields with baseline-aligned
  micro-eyebrows), red-etched chip (skips permissions). A contract never truncates
  (`fixedSize`), never hides, and holds no branch (where you launch from is the tile's
  business). Fully mute at rest: tokens only, the query materializes as you type.
  **Optical laws**: the first chip's margin = the vertical inset + round-end
  compensation (a capsule's curve eats corners), and the token strip pads 3pt inside
  its ScrollView (the viewport clips hard at x=0). Only the right edge fades —
  overflow is the only thing worth signaling. ←/→ move through tokens only while the
  field is empty; ↑/↓, ⌘1–⌘9, ⌘0 unchanged. `RepoTint` hues survive in Settings and
  the Supporter tint perk, not in the drop.
- **Prose has no em dashes and no prose semicolons**, in markdown docs and website copy
  (a deliberate, enforced house style, use commas). Code, identifiers, and code comments
  are exempt, and third-party files (e.g. an upstream awesome-list with em-dash separators)
  match their own house style.
- Monetization is a tip jar: `AppStore.allows()` returns true for everything except
  `customTint`, which now gates **tinted chips** (the selected repo's chip in its own
  bleached hue, `RepoTint.chip`, toggle in Settings → Appearance). Don't add
  functional gates.
- **Supporter unlock is manual fulfillment** (low volume): tipper emails their receipt,
  you run `Scripts/sign-license.swift <email>` (Ed25519, self-verifies against the embedded
  public key, prints a ready-to-send email), they paste the key in Settings → About.
  No webhook/server yet. A one-tap unlock is a future feature.
- Match surrounding style, keep `swift test` green, add a test when fixing logic.

## Gotchas (hard-won, read before debugging)
- **GUI PATH:** GUI apps don't inherit the shell PATH, so `claude`/`codex` aren't found.
  `ShellEnvironment.resolvedPath` resolves the login-shell PATH. It's pre-warmed **off the
  main thread** with a timeout, running it on main during a SwiftUI layout re-enters and
  trips dispatch_once (a crash we hit). Don't move it back onto the render path.
- **Palette keyboard nav:** a scoped `NSEvent` monitor drives ↑/↓ (a focused `TextField`
  swallows arrows). The results list must use **one identity scheme** (index: `ForEach(id:\.self)`
  == `.id(index)` == `selection`) and **no stack-wide `.animation(value: selection)`**, mixing
  UUID + index identities + animation made SwiftUI treat selection changes as remove/insert
  ("deselect"/jumping).
- **Palette panel is borderless on purpose:** it was `.titled` for most of its life
  (which reserves a ~32pt titlebar strip that `resize(toContentHeight:)` had to add
  back, or the last row clipped), but on macOS 26 the system draws Liquid Glass window
  chrome into that strip — a square-cornered ghost band behind the rounded glass. The
  panel is now `[.nonactivatingPanel, .borderless]` with `canBecomeKey` overridden, the
  insets are zero, and `resize` still reads the real `safeAreaInsets` so a future
  style-mask change can't silently re-clip. If it ever goes back to `.titled`: do
  **not** opt out of the safe area (`safeAreaRegions = []` loops AppKit's constraint
  pass and crashes, `.ignoresSafeArea()` hides the prompt line).
- **The drop and the notch:** the panel is `level = .statusBar` (it must draw over the
  menu bar strip to fuse with the housing; `.floating` sits below it). Notch geometry:
  `screen.safeAreaInsets.top > 0` detects it, the housing's depth IS that inset, and
  the window docks flush with `screen.frame.maxY` (notched) or `visibleFrame.maxY`
  (floating fallback). **Nothing may render behind the camera** — screenshots composite
  pixels the housing physically blocks, so a design can look fine in captures and be
  broken live; the drop hangs strictly below `restHeight`. `screencapture` shows the
  lock screen when the Mac is locked — check captures aren't black before trusting a
  recording session.
- **Drop layout laws (hard-won):** a ScrollView clips hard at x=0, so the first chip
  pads 3pt inside the scroll content or its curve shears. A capsule's round end eats
  its corners, so optical margin = geometric margin + compensation. Contract chips are
  `fixedSize` — the scrolling token strip absorbs all compression, a truncated mode
  name ("Skip permissio…") is a safety bug, not a layout bug.
- **Frecency comparator must be transitive**, no epsilon "≈ tie" band, it breaks strict
  weak ordering and makes `sort()` reshuffle the list every render.
- **New-SDK symbols need a compiler gate, not just `#available`.** Liquid Glass APIs
  (`glassEffect`, `GlassEffectContainer`) exist only in the macOS 26 SDK: `#available`
  guards runtime, but on an older toolchain (CI's macos-15 image, Xcode 16) the symbols
  don't compile at all. Wrap such call sites in `#if compiler(>=6.2)` with the legacy
  path as the compile-time fallback.
- **Agent CLI flags are version-specific.** Verify against the installed CLI's `--help`.
  Codex: yolo = `--dangerously-bypass-approvals-and-sandbox` (NOT `--full-auto`),
  safe = `--ask-for-approval untrusted` (needs a value). Claude: `--dangerously-skip-permissions`.
- **Terminal permissions (TCC):** Terminal.app/iTerm2 use AppleScript → **Automation**, Ghostty types the command → **Accessibility**, CLI terminals (kitty/Alacritty/WezTerm) need neither.
  Surfaced with actionable errors. Open-in-tab is honored by Ghostty/iTerm2/Terminal/WezTerm.
- **Code signing (important):**
  - **Unsigned/ad-hoc builds reset TCC grants on every rebuild** (the designated requirement
    is a cdhash that changes). A **Developer ID signature** has a stable cert-based requirement,
    so Accessibility/Automation grants **persist** across rebuilds. Use `Scripts/dev-install.sh`.
  - This repo lives on a **fileprovider-managed volume** (iCloud Documents) that re-adds the
    `com.apple.FinderInfo` "detritus" codesign rejects, so **both `package.sh` and `dev-install.sh`
    assemble + sign in a TMPDIR scratch dir**, then copy the DMG back to `.build/release`.
    `ditto --noextattr --norsrc` the SPM bundles in (not `cp -R`) so they don't carry forks.
    `xattr -c` chokes on the un-removable fileprovider xattr, delete FinderInfo/ResourceFork
    **per-file** (`-exec`, not batched `xargs`).
  - **SPM ships flat resource bundles** (no Info.plist) → codesign calls them "unsuitable", `package.sh` injects a minimal Info.plist and signs them. Sparkle's nested XPC/Updater.app
    must be signed **inside-out before the app**. (Sign off a fileprovider volume, CI runners are fine.)
- **Notarization:** needs a notarytool keychain profile. One-time:
  `xcrun notarytool store-credentials tintpad-notary --apple-id erik@sorkila.com --team-id 78ACS592J2`
  (uses an **app-specific** password, not the Apple ID password). `release.sh` reads it via
  `NOTARY_PROFILE`. `package.sh` staples the **DMG** (Gatekeeper still accepts the app inside;
  stapling the .app too would be more robust offline).
- **Sparkle `sign_update`** reads the ED private key from the login keychain and triggers a
  **GUI keychain-approval prompt**, so it hangs in headless/sandboxed shells. Run it in a real
  terminal, click "Always Allow", paste the `edSignature`/`length` into `web/appcast.xml`.
  `SUPublicEDKey` (Info.plist) must match that key.
- **release.sh notes:** pass release notes via `--notes-file`, not `--notes "$(cat <<EOF…)"`,
  a heredoc inside `$(...)` trips bash with "bad substitution" on the parens/backticks.
- **Direct download URL:** link `releases/latest/download/Tintpad.dmg` (stable latest-asset URL,
  always the newest release) since `release.sh` always names the asset `Tintpad.dmg`.
- **Homebrew 6.x trusts third-party taps explicitly:** a fresh `brew install --cask sorkila/tap/tintpad`
  prompts to trust the tap once (or `brew trust sorkila/tap`). The cask mirrors LockPaw's
  (`depends_on macos: :sonoma`, not `">= :sonoma"` which errors). Tap repo is `sorkila/homebrew-tap`.
- **GitHub Actions:** never reference `secrets` in an `if:`, it fails the workflow at parse time
  on every push (a "startup failure"). Map secrets to **job-level `env`** and gate on `env.X`.
- **Settings:** don't put multiple SwiftUI `.menu` Pickers in one `Form` (AttributeGraph crash on
  this SDK), use `PopUpPicker` (NSPopUpButton wrapper).

## Repo layout
- `Sources/Tintpad/`, app. `Tests/TintpadTests/`, unit tests. `Resources/`, Info.plist, icns, entitlements.
- `web/`, marketing site: a single hand-written `index.html` (no build step, kept lean ~18KB),
  `appcast.xml`, and `assets/` (demo.mp4, demo-poster.jpg, og.png). Uses umami analytics + full
  Open Graph / Twitter-card meta (og.png is the share card). Auto-deploys to tintpad.com via
  `.github/workflows/deploy-web.yml`.
- `Scripts/`, package / dev-install / release / sign-license / uitest. `Casks/tintpad.rb`, Homebrew cask
  (mirrored into the separate `sorkila/homebrew-tap` repo, which is what `brew` installs from).
- `docs/`, ARCHITECTURE, AUDIT, RELEASE, HOMEBREW, DEMO, good-first-issues. `ROADMAP.md`, `CHANGELOG.md` at root.
- `secrets/` (gitignored), Ed25519 license **private** key (`sign-license.swift` reads it). `private/` (gitignored),
  internal GTM/launch docs (launch-copy.md, launch-plan.md). **Never commit these.**
