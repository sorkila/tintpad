# Tintpad — Release & Launch Handoff

Everything below needs your accounts/credentials, so it's documented rather than
automated. The app code for each is already wired.

## 1. Code signing + notarization
- Developer ID Application cert in the login keychain.
- Store notary creds once: `xcrun notarytool store-credentials` → profile name.
- Run: `SIGN_IDENTITY="Developer ID Application: … (TEAMID)" NOTARY_PROFILE="<profile>" ./Scripts/package.sh`
- Produces a signed, hardened-runtime, notarized, stapled DMG.

## 2. Sparkle auto-update
- Generate keys: `./Sparkle/bin/generate_keys` (private key → Keychain; prints public).
- Put the public key in `Resources/Info.plist` → `SUPublicEDKey`.
- Embed `Sparkle.framework` (with its XPCServices) into `Contents/Frameworks` of
  the release `.app` — SPM links Sparkle statically and does NOT include the
  privileged install helpers. See the note in `Scripts/package.sh`.
- Generate the appcast from your releases dir: `./Sparkle/bin/generate_appcast <dir>`
  (signs each DMG, fills `sparkle:edSignature` + `length`). Template: `Scripts/appcast.xml`.
- Host `appcast.xml` at `https://tintpad.com/appcast.xml` (matches `SUFeedURL`).

## 3. Licensing server
- Private signing key + format + a working sample key: `secrets/license-private-key.txt` (gitignored).
- On purchase (Lemon Squeezy / Paddle webhook), sign `{"email","plan":"pro","iat"}`
  with the Ed25519 private key and email the buyer `base64(payload).base64(sig)`.
- The app verifies offline against the embedded public key in `LicenseManager.swift`.

## 4. Distribution
- Homebrew cask pointing at the notarized DMG (mirror the LockPaw cask).
- GitHub repo: `sorkila/tintpad` (referenced by the landing page + About).

## 5. GTM (from the brief)
- **Pre-launch:** LinkedIn build-in-public; `web/index.html` landing page at
  tintpad.com with the waitlist form wired to your email provider
  (`REPLACE_WITH_EMAIL_PROVIDER_ENDPOINT`).
- **Launch day:** Product Hunt (00:01 PT, $4.99 intro), Show HN
  ("summon any coding agent into your terminal at the right repo in 2s"),
  r/macapps · r/ClaudeAI · r/commandline · r/swift.
- **Sustain:** SEO blog posts (the GUI PATH problem; Safe vs YOLO; per-terminal
  setup guides), a complementary Raycast extension, free Pro licenses to
  AI-coding YouTubers/newsletters, keep the core open for the GitHub-star halo.
- **Watch:** waitlist conversion, launch-day downloads, free→Pro at $4.99 vs
  $9.99, review velocity, which terminal adapters dominate.
