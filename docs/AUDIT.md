# Tintpad — Security & Code-Quality Audit

_June 2026. Perspectives: shell/command-injection, AppleScript/keystroke injection,
permissions & distribution, secrets/crypto, concurrency, error-handling,
testability, resource management, accessibility._

Severity: **Critical / High / Medium / Low / Info**. Each finding cites the code.

---

## Security

### S1 — Unquoted `{repoName}` / `{branch}` / `{remote}` in templates — **Medium**
`CommandTemplate.substitute` shell-quotes `{repoPath}` and `{prompt}` but interpolates
`{repoName}`, `{branch}`, `{remote}` raw (`CommandTemplate.swift:61–63`). A template that
uses them (e.g. `claude {repoName}`) combined with an adversarial directory or branch name
(`$(...)`, backticks, `;`) yields shell injection when the command runs.
Likelihood is low (the values are local and the default templates don't use them), impact is
arbitrary local command execution.
**Fix:** shell-quote every interpolated value (reuse `shellQuotePath`), or quote on use.

### S2 — Newlines / control chars not stripped → AppleScript & keystroke breakage/injection — **Medium**
`appleScriptEscape` escapes `\` and `"` only (`TerminalAdapter.swift`). A prompt or value
containing a newline (a) breaks the AppleScript string literal in `do script`, and (b) when
typed via the Ghostty `keystroke` adapter, **submits the line early** — effectively running a
partial command and typing the rest as a second command. `promptArgument` trims edge
whitespace but not interior newlines (`CommandTemplate.swift:84`).
**Fix:** strip control characters / collapse newlines from `{prompt}` and interpolated values
before building the command; escape newlines for AppleScript.

### S3 — Offline license is client-side, therefore patchable — **Low (accepted)**
`LicenseManager` verifies an Ed25519 signature against an embedded public key — sound crypto,
but it runs on the client, so a determined user can patch the binary to force `isPro`. This is
inherent to any offline, no-account licensing and acceptable for a one-time unlock. No server
round-trip by design. No action beyond awareness.

### S4 — Sparkle update channel not yet secured — **High (release blocker)**
`Info.plist` ships a placeholder `SUPublicEDKey`. Until real EdDSA keys are generated
(`generate_keys`), the appcast is signed, and `Sparkle.framework` is embedded, auto-update is
inert — and must never point at an unsigned feed. Tracked in `docs/RELEASE.md`.

### S5 — Not yet signed / notarized — **High (release blocker)**
`Scripts/package.sh` signs + notarizes only when `SIGN_IDENTITY`/`NOTARY_PROFILE` are set.
Required before any distribution (Gatekeeper, hardened runtime). Tracked in `docs/RELEASE.md`.

### S6 — `zsh -lic` runs the user's full shell init — **Low**
PATH resolution spawns the login+interactive shell (`ShellEnvironment.pathFromLoginShell`),
executing the user's rc files. That's their own config (acceptable), but a slow/hanging rc
blocks the **main-thread pre-warm at launch** (`AppDelegate`) → see Q1.

### S7 — Secrets handling — **Info (good)**
GitHub PAT in the Keychain (`Keychain.swift`); license private key is gitignored
(`secrets/`); the stored license key in `store.json` is a signed token, not a secret.
Entitlements are minimal (`apple-events` only; sandbox intentionally off). No telemetry.

---

## Code quality

### Q1 — No timeouts on `Process` (esp. main-thread PATH pre-warm) — **Medium**
`ShellEnvironment.resolvedPath` is forced on the main thread at launch and shells out with
`waitUntilExit()` and no timeout; `WorktreeService`/`GitHubService`/terminal `open` likewise.
A hung shell, git, or terminal blocks the UI.
**Fix:** add a timeout (kill after N s) to the PATH probe and run it off the main thread (or
cache to disk); bound the git/clone calls.

### Q2 — Launch path not injectable → UI tests are flaky, logic untested — **Medium**
`LaunchService` calls `TerminalRegistry`/`DispatchService` directly, so the only end-to-end
coverage is the GUI `uitest.sh` (synthetic keystrokes, timing-sensitive).
**Fix:** introduce a `Launcher` protocol injected into `LaunchService`/`PaletteModel`, enabling
deterministic unit tests of resolve→launch without real terminals.

### Q3 — Silent `try?` swallows failures — **Low**
e.g. `LaunchService.resumeLast`, `RecentsSettingsView.resume`, `LaunchAtLogin.set`. Failures
vanish. Surface them via the existing `status` channel / a log.

### Q4 — Dispatch logs accumulate forever — **Low**
`DispatchService` writes `~/Library/Application Support/Tintpad/dispatch/*.log` with no
rotation. Add cleanup (keep last N / prune by age).

### Q5 — Thin automated coverage — **Low**
11 unit tests cover pure logic (frecency, template, git parse, license, discovery). Untested:
terminal command-building (extract a pure `buildCommand` to test without launching), store
persistence/migration, license-apply flow, frecency ordering.

### Q6 — Accessibility (VoiceOver) labels — **Info**
Keyboard-first is excellent; Reduce Motion is honored. Missing: VoiceOver labels/traits on
palette rows and controls. Add `.accessibilityLabel`/`.accessibilityElement` for screen readers.

### Q7 — No CI — **Info**
Add GitHub Actions: `swift build` + `swift test` on push; optional release job.

### Q8 — Concurrency / resources — **Info (mostly fine)**
`@MainActor` is applied consistently; the dispatch termination handler hops back to main; the
`NSEvent` monitor is app-lifetime (acceptable). FileHandles are closed. No action.

---

## Plan

### Phase 1 — Pre-release hardening (small, high value)
1. **S1**: shell-quote all interpolated template variables.
2. **S2**: strip control chars / newlines from prompt + interpolated values; escape for AppleScript.
3. **Q1**: timeout + off-main the PATH pre-warm (and bound git/clone).
4. Add focused tests for the new sanitization (extends Q5).

### Phase 2 — Release security (blocking distribution)
5. **S4/S5**: Developer-ID sign + notarize, Sparkle `generate_keys` + signed appcast + embedded framework (per `docs/RELEASE.md`).

### Phase 3 — Quality & maintainability
6. **Q2**: injectable `Launcher`; deterministic launch tests.
7. **Q4** dispatch-log rotation; **Q3** surface swallowed errors.
8. **Q6** VoiceOver labels; **Q7** CI workflow.

Recommended next step: implement **Phase 1 (S1, S2, Q1)** now — it's a couple of focused,
well-testable changes that close the only real injection vectors.
