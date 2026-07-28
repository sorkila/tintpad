# CLAUDE.md

Guidance for Claude Code (and contributors) working in this repo.

## What this is
**Tintpad**, a native macOS (Swift/SwiftUI) menu-bar launcher. Global hotkey →
floating palette → fuzzy-find a repo (frecency-ranked) → pick agent + run mode →
your terminal opens at that repo with the agent (Claude Code, Codex, …) running.
Hands off to *your* terminal, it isn't one. Accessory app (`LSUIElement`), local-only,
no accounts. **Free & open source (MIT) + optional Supporter tip.**

## Status (shipped)
**v0.2.0 is live** (2026-07-28): the 2.0 pass — Liquid Glass ⌘Tab palette, launch
memory, agent-vocabulary modes, three-audit hardening. Notarized DMG at
`github.com/sorkila/tintpad/releases/tag/v0.2.0`,
direct download via `releases/latest/download/Tintpad.dmg`, site live at tintpad.com,
Homebrew tap at `sorkila/homebrew-tap` (`brew install --cask sorkila/tap/tintpad`),
Sparkle auto-update wired (`web/appcast.xml` → tintpad.com/appcast.xml). Bump the version
in `Resources/Info.plist` then run `./Scripts/release.sh` to cut the next one.

## Commands
```sh
swift build              # debug build
swift test               # 47 unit tests (pure logic, keep green)
swift run                # run from source (dev; unsigned)
./Scripts/package.sh     # assemble + sign .app/DMG in a TMPDIR scratch (signs if SIGN_IDENTITY set)
./Scripts/dev-install.sh # build → Developer ID sign → install to /Applications (local dev)
./Scripts/release.sh     # one-command notarized release (needs SIGN_IDENTITY + NOTARY_PROFILE)
./Scripts/sign-license.swift <email>  # sign a Supporter key (manual tint fulfillment)
./Scripts/uitest.sh      # synthetic-input GUI smoke test (needs Accessibility/Automation)
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
- Resizable surfaces (Settings, onboarding) use the scalable `TypeRamp` (Dynamic Type), the palette is a monospace HUD on a fixed grid (its own `@ScaledMetric` point sizes, clamped to xxLarge).
- **Agent marks** (`AgentMarks.swift`). A brand mark where artwork exists, a `Monogram`
  everywhere else, so a third agent never falls back to a generic glyph. Monograms are
  assigned across the **whole agent set** (`AppStore.monogram(for:)`, the single source of
  truth) so they stay distinct, one letter until two collide. Marks are rasterized on
  demand at the exact pixel size they will be drawn, since pre-rendering at one size and
  letting SwiftUI rescale resamples twice and arrives soft. Each brand carries an
  `optical` correction because icons in a set must match in **ink, not bounding box**
  (Claude's airy radial needs to be drawn larger and held brighter than Codex's dense blob).
- **Palette design rules** (`PaletteView`, documented on the type). A floating Liquid
  Glass **cluster**, not a sheet: search pill, horizontal repo-tile strip (⌘Tab for
  repos), launch pill — three discrete glass pieces with real gaps. On macOS 26 each
  piece is real `glassEffect` in a shared `GlassEffectContainer`, pills are interactive
  glass, and **legibility comes from vibrancy** (hierarchical foreground styles on the
  glass, never flat `.opacity()` text over a heavy scrim — the frost is a whisper);
  earlier systems get the legacy vibrancy stack. **The window draws no system
  shadow** — each piece carries its own inside a transparent margin
  (`PaletteView.windowMargin`), because AppKit shadows the rectangular frame and it
  reads as a ghost box. **Every repo gets its tint** (`RepoTint`: a stable hue hashed
  from the name, the danger-red band excluded): tile identity is the repo's colored
  monogram, the agent mark is a small corner badge. The accent means "here, now"
  (the text caret, the selection), danger red means "skips permissions" (dangerous tiles
  are ringed red before you arrive). **The launch pill is the contract**: agent name, mode, `⑂ branch*` — no
  carets, no path (the selected tile already carries the name), agent/mode words quietly
  clickable (visible counterpart of ⇥/⇧⇥, real flags in the tooltip). Less but better:
  nothing renders that repeats another element or decorates. ←/→ move through the strip only while the field is empty (they
  must keep moving the caret otherwise); ↑/↓, ⌘1–⌘9, ⌘0 unchanged. One voice of type:
  SF Mono at exactly two sizes (`fieldSize`/`metaSize`), weight carries the hierarchy —
  always via `Font.mono`/`Font.monoStyle` (the one place the voice is defined), never
  `design: .monospaced` directly. Agent brand color appears on the selected tile only. **Type and the grid metrics scale together** via
  `@ScaledMetric`, because the panel height is computed from those metrics and drifts
  if only one of them scales.
- **Prose has no em dashes and no prose semicolons**, in markdown docs and website copy
  (a deliberate, enforced house style, use commas). Code, identifiers, and code comments
  are exempt, and third-party files (e.g. an upstream awesome-list with em-dash separators)
  match their own house style.
- Monetization is a tip jar: `AppStore.allows()` returns true for everything except
  `customTint` (the Supporter perk). Don't add functional gates.
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
