#!/usr/bin/env bash
# Build → Developer ID sign → install to /Applications.
#
# Signs in a scratch dir because this repo lives on a fileprovider-managed volume
# (iCloud/Documents) that re-adds the Finder-info "detritus" codesign rejects.
# The signed app has a STABLE certificate-based requirement, so macOS permission
# grants (Accessibility for Ghostty, Automation for AppleScript terminals) PERSIST
# across rebuilds — no more re-granting every time.
#
#   ./Scripts/dev-install.sh         # uses the default Developer ID below
#   SIGN_IDENTITY="…" ./Scripts/dev-install.sh
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
ID="${SIGN_IDENTITY:-Developer ID Application: Erik Nielsen (78ACS592J2)}"

echo "▸ Assembling unsigned bundle…"
./Scripts/package.sh >/dev/null

SCRATCH="${TMPDIR:-/tmp}/tintpad-sign"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
ditto --noextattr --norsrc --noacl "$REPO/.build/release/Tintpad.app" "$SCRATCH/Tintpad.app"
cd "$SCRATCH"
find Tintpad.app -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true

sign() { codesign --force --options runtime --timestamp --sign "$ID" "$@" >/dev/null; }
echo "▸ Signing with: $ID"
for b in Tintpad.app/Contents/MacOS/*.bundle; do
  [ -d "$b" ] || continue
  n="$(basename "$b" .bundle)"
  [ -f "$b/Info.plist" ] || cat > "$b/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sorkila.tintpad.$n</string>
  <key>CFBundleName</key><string>$n</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
  sign "$b"
done
FW="Tintpad.app/Contents/Frameworks/Sparkle.framework/Versions/B"
for x in "$FW/XPCServices/Downloader.xpc" "$FW/XPCServices/Installer.xpc" \
         "$FW/Autoupdate" "$FW/Updater.app" \
         "Tintpad.app/Contents/Frameworks/Sparkle.framework"; do
  [ -e "$x" ] && sign "$x"
done
codesign --force --options runtime --timestamp \
  --entitlements "$REPO/Resources/Tintpad.entitlements" --sign "$ID" Tintpad.app
codesign --verify --deep --strict Tintpad.app

echo "▸ Installing to /Applications…"
rm -rf /Applications/Tintpad.app
ditto Tintpad.app /Applications/Tintpad.app
echo "✓ Installed: /Applications/Tintpad.app"
codesign -dvv /Applications/Tintpad.app 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier" | head -2
