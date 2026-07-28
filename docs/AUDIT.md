# Tintpad, Security & Code-Quality Audit

_June 2026. Perspectives: shell/command-injection, AppleScript/keystroke injection,
permissions & distribution, secrets/crypto, concurrency, error-handling,
testability, resource management, accessibility._

Severity: **Critical / High / Medium / Low / Info**. Each finding cites the code.

---

## Security

### S1, Unquoted `{repoName}` / `{branch}` / `{remote}` in templates, **Medium**
`CommandTemplate.substitute` shell-quotes `{repoPath}` and `{prompt}` but interpolates
`{repoName}`, `{branch}`, `{remote}` raw (`CommandTemplate.swift:61–63`). A template that
uses them (e.g. `claude {repoName}`) combined with an adversarial directory or branch name
(`$(...)`, backticks, `;`) yields shell injection when the command runs.
Likelihood is low (the values are local and the default templates don't use them), impact is
arbitrary local command execution.
**Fix:** shell-quote every interpolated value (reuse `shellQuotePath`), or quote on use.

### S2, Newlines / control chars not stripped → AppleScript & keystroke breakage/injection, **Medium**
`appleScriptEscape` escapes `\` and `"` only (`TerminalAdapter.swift`). A prompt or value
containing a newline (a) breaks the AppleScript string literal in `do script`, and (b) when
typed via the Ghostty `keystroke` adapter, **submits the line early**, effectively running a
partial command and typing the rest as a second command. `promptArgument` trims edge
whitespace but not interior newlines (`CommandTemplate.swift:84`).
**Fix:** strip control characters / collapse newlines from `{prompt}` and interpolated values
before building the command, escape newlines for AppleScript.

### S3, Offline license is client-side, therefore patchable, **Low (accepted)**
`LicenseManager` verifies an Ed25519 signature against an embedded public key, sound crypto,
but it runs on the client, so a determined user can patch the binary to force `isPro`. This is
inherent to any offline, no-account licensing and acceptable for a one-time unlock. No server
round-trip by design. No action beyond awareness.

### S4, Sparkle update channel not yet secured, **High (release blocker)**
`Info.plist` ships a placeholder `SUPublicEDKey`. Until real EdDSA keys are generated
(`generate_keys`), the appcast is signed, and `Sparkle.framework` is embedded, auto-update is
inert, and must never point at an unsigned feed. Tracked in `docs/RELEASE.md`.

### S5, Not yet signed / notarized, **High (release blocker)**
`Scripts/package.sh` signs + notarizes only when `SIGN_IDENTITY`/`NOTARY_PROFILE` are set.
Required before any distribution (Gatekeeper, hardened runtime). Tracked in `docs/RELEASE.md`.

### S6, `zsh -lic` runs the user's full shell init, **Low**
PATH resolution spawns the login+interactive shell (`ShellEnvironment.pathFromLoginShell`),
executing the user's rc files. That's their own config (acceptable), but a slow/hanging rc
blocks the **main-thread pre-warm at launch** (`AppDelegate`) → see Q1.

### S7, Secrets handling, **Info (good)**
GitHub PAT in the Keychain (`Keychain.swift`), license private key is gitignored
(`secrets/`), the stored license key in `store.json` is a signed token, not a secret.
Entitlements are minimal (`apple-events` only, sandbox intentionally off). No telemetry.

---

## Code quality

### Q1, No timeouts on `Process` (esp. main-thread PATH pre-warm), **Medium**
`ShellEnvironment.resolvedPath` is forced on the main thread at launch and shells out with
`waitUntilExit()` and no timeout, `WorktreeService`/`GitHubService`/terminal `open` likewise.
A hung shell, git, or terminal blocks the UI.
**Fix:** add a timeout (kill after N s) to the PATH probe and run it off the main thread (or
cache to disk), bound the git/clone calls.

### Q2, Launch path not injectable → UI tests are flaky, logic untested, **Medium**
`LaunchService` calls `TerminalRegistry`/`DispatchService` directly, so the only end-to-end
coverage is the GUI `uitest.sh` (synthetic keystrokes, timing-sensitive).
**Fix:** introduce a `Launcher` protocol injected into `LaunchService`/`PaletteModel`, enabling
deterministic unit tests of resolve→launch without real terminals.

### Q3, Silent `try?` swallows failures, **Low**
e.g. `LaunchService.resumeLast`, `RecentsSettingsView.resume`, `LaunchAtLogin.set`. Failures
vanish. Surface them via the existing `status` channel / a log.

### Q4, Dispatch logs accumulate forever, **Low**
`DispatchService` writes `~/Library/Application Support/Tintpad/dispatch/*.log` with no
rotation. Add cleanup (keep last N / prune by age).

### Q5, Thin automated coverage, **Low**
11 unit tests cover pure logic (frecency, template, git parse, license, discovery). Untested:
terminal command-building (extract a pure `buildCommand` to test without launching), store
persistence/migration, license-apply flow, frecency ordering.

### Q6, Accessibility (VoiceOver) labels, **Info, largely addressed**
Keyboard-first is excellent, Reduce Motion is honored. Since this was written, palette rows
carry `.accessibilityElement`/`.accessibilityLabel` with selected and button traits, status
changes and pending skip-permissions launches are announced, Tab is released to focus
traversal when VoiceOver or Full Keyboard Access is on, Dynamic Type scales the palette's
type and grid together, and Reduce Transparency drops the blur for an opaque panel.
Still open: Settings and onboarding keep about ten hard-coded font sizes, and the raised
contrast has not been measured against 4.5:1 with a real checker over a worst-case desktop.

### Q7, No CI, **Info**
Add GitHub Actions: `swift build` + `swift test` on push, optional release job.

### Q8, Concurrency / resources, **Info (mostly fine)**
`@MainActor` is applied consistently, the dispatch termination handler hops back to main, the
`NSEvent` monitor is app-lifetime (acceptable). FileHandles are closed. No action.

---

## Plan & status

### Phase 1, Pre-release hardening, ✅ DONE
1. **S1** ✅ every interpolated template variable is now sanitized + single-quoted (`CommandTemplate.quote`).
2. **S2** ✅ control chars/newlines stripped (`CommandTemplate.sanitize`), `appleScriptEscape` also neutralizes newlines.
3. **Q1** ✅ PATH probe has a 4s timeout, pre-warm moved off the main thread.
4. ✅ injection tests added (quote-break, single-quote escaping, newline stripping), 14 tests green.

### Phase 2, Release security, ⏳ needs Developer ID / accounts
5. **S4/S5**: sign + notarize, Sparkle `generate_keys` + signed appcast + embedded framework (per `docs/RELEASE.md`). Cannot complete without the cert/notary account.

### Phase 3, Quality & maintainability, ✅ mostly done
6. **Q2**, pure command-building (the injection surface) is now unit-tested deterministically, a full injectable `Launcher` for end-to-end launch tests remains as a nice-to-have.
7. **Q4** ✅ dispatch logs rotate (keep last 30). **Q3** partial, resume failures beep, broader surfacing still TODO.
8. **Q6** ✅ VoiceOver labels on palette rows + search field. **Q7** ✅ GitHub Actions CI (`build` + `test`).

Remaining: Phase 2 (release creds), full `Launcher` DI, broader error surfacing.

---

# 2026-07 audit, post-2.0 redesign

_Three parallel audit passes (concurrency/lifecycle, robustness/error handling,
security + palette state machine) over the Liquid Glass cluster codebase, every
finding verified against source before inclusion. Fixed items were fixed the
same day, commit-referenced below._

## Fixed in this pass

### Dangerous-mode confirm gate (was: five bypasses)
- **Click/⌘n fired a pending YOLO for a different repo** (High). `activate(at:)`
  and `launchByIndex` consumed the pending confirm armed for repo A when the
  user clicked or jumped to repo B. Both now cancel a pending confirm instead.
- **Dispatch, prompt, worktree, and resume skipped the confirm setting**
  (Medium). All launch paths now route through one gate
  (`PaletteModel.fireOrConfirm`), and the pending launch carries its own replay
  action, so no flow is quieter than plain ⏎.
- ⌘0 with a dangerous last session arms the same banner.

### State machine
- **Agent/mode overrides leaked across repos** (Medium): typing reset the
  selection but kept the override, silently applying it to whichever repo
  became row 0. `query.didSet` now clears overrides.
- Worktree and prompt modes were not mutually exclusive (Medium): entering one
  now exits the other.
- `activate(at:)` validates the tapped index instead of clamping a stale one.

### Data safety
- **Corrupt store.json was silently reseeded and persisted over** (High), which
  destroyed repos, sessions, settings, and the Supporter key with no trace. The
  failed file is now preserved as `store.corrupt-<ts>.json`, and the seed only
  persists on a true first run.
- `persist()` no longer swallows write errors silently (logged).
- Deleting the last agent (which dead-keyed the palette) is now refused.

### Concurrency / robustness
- **Git dirty-checks blocked the Swift cooperative pool** (High): a repo on a
  stalled mount could pin pool threads app-wide. The check now runs on a
  dedicated GCD queue, `GitStatus` escalates SIGTERM to SIGKILL, and the dirty
  path closes its pipe before waiting so a chatty child can't deadlock.
- `reset()` now clears `gitInFlight`, so a hung fetch can't lock a repo out of
  git context for the app's lifetime.
- Launch-time auto-discovery genuinely runs in the background now (it was
  synchronous on the main thread despite its comment), same for the
  empty-store summon path.
- The global space-collapse in `CommandTemplate` rewrote double spaces inside
  quoted paths and prompts (Medium): replaced with targeted empty-slot cleanup,
  regression-tested.
- Worktree branch names are pinned behind `--` / `refs/heads/` so a
  dash-leading name can't parse as a git option.
- Recents resume failures now beep instead of vanishing (June Q3 call site).

## Verified clean
Command quoting end to end including `{branch}`/`{remote}`/`{worktreePath}` and
AppleScript escaping, DispatchService lifecycle + log rotation, the
`tintpad://` scheme (summon-only), license key handling (public key only in the
bundle), Store main-actor discipline, notification observer lifecycle,
GitStatus argv/env hygiene.

## Open, ranked
1. **Main-actor `waitUntilExit` in clone/worktree/terminal adapters** (High for
   clone, Medium otherwise): `GitHubService.clone` runs a full clone on the
   main actor (its `Task {}` inherits MainActor), worktree add and adapter
   `run()` can block the UI, and all three read pipes after exit (64KB
   deadlock). Needs the same treatment GitStatus got, plus async clone.
2. **No single-instance guard**: dev build + installed app last-writer-wins on
   store.json.
3. `resumeLast` collapses "gone" and "failed" into one message, and
   `hasLastSession` advertises resumes that can't reconstruct.
4. Ghostty keystroke adapter types into whatever is frontmost after its fixed
   delays (no frontmost re-check), Terminal tab mode lacks the Accessibility
   pre-check, Warp URL needs `URLComponents`.
5. Frecency inflates scores for future-dated `lastLaunchedAt` (clock rollback).
6. Settings `bind()` rewrites the whole store per keystroke (perf).
7. Dispatch: no cancel/timeout/visibility for running agents, log name
   collision within one second.
8. Global resume hotkey bypasses the dangerous-mode confirm by design (no UI
   surface to confirm in); documented tradeoff, revisit if it bites.
