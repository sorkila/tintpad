# Tintpad, Release & Launch Handoff

The pipeline is wired and the Sparkle key is set. The remaining steps need your
Apple Developer credentials, which only you can supply.

## Release in 3 commands
```sh
# 1. One-time: store notary creds in a keychain profile
xcrun notarytool store-credentials tintpad-notary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

# 2. Build → sign → notarize → staple → DMG (one command)
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="tintpad-notary" ./Scripts/package.sh
#   → .build/release/Tintpad.dmg (notarized + stapled; prints the sha256)

# 3. Sign the appcast entry and publish it
.build/artifacts/sparkle/Sparkle/bin/sign_update .build/release/Tintpad.dmg
#   → paste sparkle:edSignature + length into Scripts/appcast.xml, host it at
#     https://tintpad.com/appcast.xml (commit appcast under web/ to auto-deploy it)
```
Without `SIGN_IDENTITY`, `package.sh` still produces a runnable **unsigned DMG**
for local testing.

## What's already done
- ✅ **Sparkle public key** is in `Info.plist` (`SUPublicEDKey`), the private key
  is in your login Keychain (shared with your other apps). `generate_keys` already ran.
- ✅ `package.sh` embeds `Sparkle.framework` and signs its nested XPC services /
  Autoupdate / Updater.app **inside-out before the app** (the notarization gotcha).
- ✅ Always emits a DMG, notarizes + staples it when creds are present, and prints its sha256.
- ⏳ You provide: the Developer ID cert + notary profile (step 1–2 above).

## Homebrew (after the first notarized DMG)
- Fill `version` + the printed `sha256` into `Casks/tintpad.rb`, push to
  `sorkila/homebrew-tap`. See `docs/HOMEBREW.md`.

## 3. Licensing server
- Private signing key + format + a working sample key: `secrets/license-private-key.txt` (gitignored).
- On purchase (Lemon Squeezy / Paddle webhook), sign `{"email","plan":"pro","iat"}`
  with the Ed25519 private key and email the buyer `base64(payload).base64(sig)`.
- The app verifies offline against the embedded public key in `LicenseManager.swift`.

## 4. Distribution
- Homebrew cask pointing at the notarized DMG (mirror the LockPaw cask).
- GitHub repo: `sorkila/tintpad` (referenced by the landing page + About).

## 5. GTM (from the brief)
- **Pre-launch:** LinkedIn build-in-public, `web/index.html` landing page live at
  tintpad.com with a direct download (no waitlist, it's free).
- **Launch day:** Product Hunt (00:01 PT), Show HN ("summon any coding agent into
  your terminal at the right repo in 2s"), r/macapps · r/ClaudeAI · r/ChatGPTCoding ·
  r/commandline · r/swift.
- **Sustain:** SEO blog posts (the GUI PATH problem, Safe vs YOLO, per-terminal
  setup guides), a complementary Raycast extension, the open-source GitHub-star halo.
- **Watch:** GitHub stars, launch-day downloads, which terminal adapters dominate,
  tip volume, review velocity.
