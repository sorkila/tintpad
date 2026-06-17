# Security policy

Tintpad runs commands in your terminal on your behalf, so security reports are taken
seriously.

## Reporting

Please report vulnerabilities **privately** via
[GitHub Security Advisories](https://github.com/sorkila/tintpad/security/advisories/new),
not a public issue. I'll acknowledge within a few days.

Especially interested in:
- Command or AppleScript **injection** via repo paths, branch names, prompts, or agent templates.
- Anything that runs a command the user didn't intend, or escapes the sanitization/quoting in `CommandTemplate`.
- Misuse of the Accessibility / Automation permissions.

## What's already known / by design

- **The offline license is client-side and patchable.** That's intentional — Tintpad is
  MIT and free; the Supporter unlock is a tip, not DRM. "Bypassing" it isn't a vulnerability.
- **It needs Accessibility only for Ghostty** (which has no command-open API on macOS, so
  Tintpad types the command). It's optional and scoped to launching.
- **Local-only**: no accounts, no telemetry. A GitHub PAT (if you add one) lives in the Keychain.

See [docs/AUDIT.md](docs/AUDIT.md) for the security/quality audit and what's been hardened.
