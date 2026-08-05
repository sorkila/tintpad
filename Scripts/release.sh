#!/usr/bin/env bash
# One-command release. Build → sign → notarize → DMG → GitHub Release →
# Sparkle appcast → Homebrew cask. The only thing you provide is your cert.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="tintpad-notary" \
#   ./Scripts/release.sh [version]
#
# Prereqs (one-time): `xcrun notarytool store-credentials tintpad-notary …`
# and `gh auth login`. Version defaults to CFBundleShortVersionString.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGN_IDENTITY:?set SIGN_IDENTITY — \"Developer ID Application: Name (TEAMID)\"}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE — your notarytool keychain profile name}"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
TAG="v${VERSION}"
REPO="sorkila/tintpad"
DMG=".build/release/Tintpad.dmg"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
DL="https://github.com/${REPO}/releases/download/${TAG}/Tintpad.dmg"

echo "▸ Releasing Tintpad ${VERSION} (${TAG})"

# 1. Build, sign, notarize, staple, DMG.
./Scripts/package.sh
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "▸ DMG sha256: ${SHA}"

# 2. GitHub Release with the DMG. Notes go via a temp file (a heredoc inside
# $(...) trips bash on the parens/backticks in the body).
NOTES_FILE="$(mktemp)"
cat > "$NOTES_FILE" <<EOF
**Tintpad**: press ⌥⌘Space and a black drop falls out of your Mac's notch with your repos
inside. Return opens your terminal at that repo with your coding agent (Claude Code, Codex, …)
already running. Hands off to the terminal you already use. Native, local-only, free and open
source.

### Install
- **Download \`Tintpad.dmg\` below**, drag to Applications, launch. macOS 14+.
- or \`brew install --cask sorkila/tap/tintpad\`
- The build is signed with a Developer ID and notarized, so it opens past Gatekeeper. Auto-updates via Sparkle.

### What's inside
- **The drop**: a pure-black capsule that falls from the camera housing (a floating pill below
  the menu bar on notchless Macs). Stark black and white, springs all the way down, a crossfade
  under Reduce Motion.
- **The contract**: AGENT and MODE chips say exactly what Return runs, in each agent's own
  words. The mode that skips permissions is a red-etched chip, and every permission-skipping
  path shares one confirm gate.
- Repos remember how you opened them last, ⌘0 replays your last session exactly.
- Frecency search, git worktrees (⌃W), headless dispatch (⌃↵), prompt library, per-repo
  presets, GitHub import.
- 7 terminals: Ghostty, iTerm2, kitty, WezTerm, Alacritty, Terminal.app, Warp.
- Local-only: no accounts, no telemetry, nothing leaves your Mac.
- Free and MIT, the whole app. The optional Supporter tip only unlocks tinted chips (the
  selected repo's chip blooms in its own hue).

Full notes: [CHANGELOG.md](https://github.com/${REPO}/blob/main/CHANGELOG.md) · sha256 \`${SHA}\`
EOF
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --clobber -R "$REPO"
  gh release edit "$TAG" -R "$REPO" --title "Tintpad ${VERSION}" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" "$DMG" -R "$REPO" --title "Tintpad ${VERSION}" --notes-file "$NOTES_FILE"
fi
rm -f "$NOTES_FILE"

# 3. Sparkle appcast (auto-deploys via web/ → tintpad.com/appcast.xml).
SIG="$("$SIGN_UPDATE" "$DMG")"   # → sparkle:edSignature="…" length="…"
cat > web/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Tintpad</title>
    <link>https://tintpad.com/appcast.xml</link>
    <item>
      <title>${VERSION}</title>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${DL}" ${SIG} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
echo "▸ Wrote web/appcast.xml — commit + push to deploy it."

# 4. Homebrew cask.
sed -i '' -E "s/version \"[^\"]*\"/version \"${VERSION}\"/" Casks/tintpad.rb
sed -i '' -E "s/sha256 \"[0-9a-f]*\"/sha256 \"${SHA}\"/" Casks/tintpad.rb
echo "▸ Casks/tintpad.rb set to ${VERSION} / ${SHA}"

cat <<DONE

✓ Release ${TAG} is up: https://github.com/${REPO}/releases/tag/${TAG}
Next:
  1. git add web/appcast.xml Casks/tintpad.rb && git commit -m "release ${VERSION}" && git push
     (push deploys appcast.xml to tintpad.com automatically)
  2. Copy Casks/tintpad.rb into the sorkila/homebrew-tap repo.
  3. Test: brew install --cask sorkila/tap/tintpad
DONE
