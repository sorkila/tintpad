#!/usr/bin/env bash
# Assemble Tintpad.app from the SwiftPM release build, then (optionally) sign,
# notarize, and staple — mirroring the LockPaw pipeline.
#
# Signing/notarization are skipped unless the relevant env vars are set, so this
# script produces a runnable (unsigned) .app out of the box for local testing.
#
#   SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE  notarytool keychain profile name (xcrun notarytool store-credentials)
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tintpad"
BUILD_DIR=".build/release"
APP="${BUILD_DIR}/${APP_NAME}.app"

echo "▸ Building release…"
swift build -c release

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
# Bundle the SwiftPM resource bundles (e.g. KeyboardShortcuts) next to the binary.
cp -R "$BUILD_DIR"/*.bundle "$APP/Contents/MacOS/" 2>/dev/null || true

# Embed Sparkle.framework (SPM builds it as a dynamic framework). The binary's
# rpaths include @loader_path; we also add @executable_path/../Frameworks so the
# conventional location works and notarization is happy.
SPARKLE_FW="$BUILD_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi
# At release time also replace SUPublicEDKey in Info.plist with the output of
# Sparkle's ./bin/generate_keys (private key stays in your Keychain).

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "▸ Signing with hardened runtime…"
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    --entitlements "Resources/Tintpad.entitlements" \
    "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "▸ SIGN_IDENTITY not set — skipping signing (app will run locally only)."
fi

if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
  DMG="${BUILD_DIR}/${APP_NAME}.dmg"
  echo "▸ Creating DMG and notarizing…"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "▸ Notarized DMG: $DMG"
fi

echo "✓ Done: $APP"
