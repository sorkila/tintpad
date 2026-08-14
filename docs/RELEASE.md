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

## 3. Supporter keys (manual fulfillment)
The only Supporter perk is tinted chips. Fulfillment is manual at launch (low volume):
a Buy Me a Coffee tip, then the supporter emails their receipt and you send a key.

```sh
# generates a key that verifies offline against the embedded public key, and
# prints a ready-to-send email. The key is self-verified before it prints.
swift Scripts/sign-license.swift buyer@example.com
```
- Private signing key + format + a working sample key: `secrets/license-private-key.txt` (gitignored).
- The app verifies the key offline against the embedded public key in `LicenseManager.swift`.
  The buyer pastes it in Settings, About, "Paste supporter key", Activate.
- To automate later: a Lemon Squeezy / Gumroad / Paddle webhook can call a small signing
  endpoint that runs the same logic as `Scripts/sign-license.swift` and emails the key.

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
