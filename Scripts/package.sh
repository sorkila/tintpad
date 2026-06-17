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

# Sparkle note: SPM links Sparkle statically, so "check for updates" + download
# work, but the privileged auto-INSTALL helpers (Installer.xpc, Autoupdate) ship
# inside Sparkle.framework and must be embedded for full auto-update. For the
# release build, download Sparkle's binary framework and embed it:
#   mkdir -p "$APP/Contents/Frameworks"
#   cp -R /path/to/Sparkle.framework "$APP/Contents/Frameworks/"
# then sign it (codesign --deep is discouraged; sign nested code first).
# Also replace SUPublicEDKey in Info.plist with the output of:
#   ./Sparkle/bin/generate_keys        # private key -> Keychain, prints public

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
