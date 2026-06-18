# CLAUDE.md

Guidance for Claude Code (and contributors) working in this repo.

## What this is
**Tintpad**, a native macOS (Swift/SwiftUI) menu-bar launcher. Global hotkey →
floating palette → fuzzy-find a repo (frecency-ranked) → pick agent + run mode →
your terminal opens at that repo with the agent (Claude Code, Codex, …) running.
Hands off to *your* terminal, it isn't one. Accessory app (`LSUIElement`), local-only,
no accounts. **Free & open source (MIT) + optional Supporter tip.**

## Commands
```sh
swift build              # debug build
swift test               # 19 unit tests (pure logic, keep green)
swift run                # run from source (dev; unsigned)
./Scripts/package.sh     # assemble .build/release/Tintpad.app (+ DMG; signs if SIGN_IDENTITY set)
./Scripts/dev-install.sh # build → Developer ID sign → install to /Applications (local dev)
./Scripts/release.sh     # notarized release (needs SIGN_IDENTITY + notary creds)
./Scripts/uitest.sh      # synthetic-input GUI smoke test (needs Accessibility/Automation)
```
Swift 6, macOS 14+. Deps (SPM): KeyboardShortcuts, Sparkle.

## Architecture (see docs/ARCHITECTURE.md for detail)
- **Models.swift / Store.swift**, Codable model + `AppStore` (@MainActor), JSON at
  `~/Library/Application Support/Tintpad/store.json`. Tolerant decoders (adding a field never reseeds).
- **PaletteView.swift / CommandPanel.swift**, the palette (NSPanel + SwiftUI) and its controller.
- **TerminalAdapter.swift**, 7 terminal adapters. **CommandTemplate.swift**, command building (the injection surface).
- **LaunchService.swift**, `makeLaunch` (pure, tested) + injectable `resolveTerminal`.
- **ShellEnvironment.swift**, login-shell PATH resolution. **Frecency.swift**, ranking.
- **SettingsView.swift** (+ per-pane views), **OnboardingView.swift**, **LicenseManager.swift**, **Tokens.swift**.

## Conventions
- All command building goes through `CommandTemplate`, every interpolated value is
  sanitized (control chars stripped) and POSIX single-quoted. Never hand-build shell or AppleScript strings.
- Resizable surfaces (Settings, onboarding) use the scalable `TypeRamp` (Dynamic Type), the palette is a fixed-size HUD with tuned point sizes (with `@ScaledMetric`, clamped to xxLarge).
- Monetization is a tip jar: `AppStore.allows()` returns true for everything except
  `customTint` (the Supporter perk). Don't add functional gates.
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
- **Frecency comparator must be transitive**, no epsilon "≈ tie" band, it breaks strict
  weak ordering and makes `sort()` reshuffle the list every render.
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
    `com.apple.FinderInfo` "detritus" codesign rejects, so **sign in a scratch dir** (dev-install.sh
    does this). `xattr -c` chokes on the un-removable fileprovider xattr, delete FinderInfo/ResourceFork
    **per-file** (`-exec`, not batched `xargs`).
  - **SPM ships flat resource bundles** (no Info.plist) → codesign calls them "unsuitable", `package.sh` injects a minimal Info.plist and signs them. Sparkle's nested XPC/Updater.app
    must be signed **inside-out before the app**. (Sign off a fileprovider volume, CI runners are fine.)
- **GitHub Actions:** never reference `secrets` in an `if:`, it fails the workflow at parse time
  on every push (a "startup failure"). Map secrets to **job-level `env`** and gate on `env.X`.
- **Settings:** don't put multiple SwiftUI `.menu` Pickers in one `Form` (AttributeGraph crash on
  this SDK), use `PopUpPicker` (NSPopUpButton wrapper).

## Repo layout
- `Sources/Tintpad/`, app. `Tests/TintpadTests/`, unit tests. `Resources/`, Info.plist, icns, entitlements.
- `web/`, marketing site (auto-deploys to tintpad.com via `.github/workflows/deploy-web.yml`).
- `Scripts/`, package / dev-install / release / uitest. `Casks/tintpad.rb`, Homebrew cask.
- `docs/`, ARCHITECTURE, AUDIT, RELEASE, HOMEBREW, DEMO, ROADMAP, good-first-issues.
- `secrets/` (gitignored), Ed25519 license private key. `private/` (gitignored), internal strategy docs.
