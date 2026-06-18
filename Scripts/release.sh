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

# 2. GitHub Release with the DMG.
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --clobber -R "$REPO"
else
  gh release create "$TAG" "$DMG" -R "$REPO" \
    --title "Tintpad ${VERSION}" --notes "See CHANGELOG.md"
fi

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
