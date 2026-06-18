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
cp "Resources/Tintpad.icns" "$APP/Contents/Resources/Tintpad.icns"
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
  sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
  # Sparkle: sign the nested code inside-out BEFORE the app, or notarization fails.
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$FW" ]]; then
    V="$FW/Versions/B"
    for x in "$V/XPCServices/Downloader.xpc" "$V/XPCServices/Installer.xpc" \
             "$V/Autoupdate" "$V/Updater.app"; do
      [[ -e "$x" ]] && sign "$x"
    done
    sign "$FW"
  fi
  # The app itself carries the entitlements.
  codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    --entitlements "Resources/Tintpad.entitlements" \
    "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "▸ SIGN_IDENTITY not set — skipping signing (app runs locally only)."
fi

# Always build a DMG so there's a testable/distributable artifact.
DMG="${BUILD_DIR}/${APP_NAME}.dmg"
echo "▸ Creating ${DMG}…"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
  echo "▸ Notarizing…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "▸ Notarized DMG: $DMG  (sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1))"
else
  echo "▸ Unsigned DMG (local testing only): $DMG"
fi

echo "✓ Done: $APP"
