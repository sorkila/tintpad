#!/usr/bin/env bash
# Structural check of an assembled Tintpad.app and its DMG, signed or not.
# CI runs it after an unsigned ./Scripts/package.sh, so a packaging regression
# (a missing resource bundle, Sparkle not embedded, a lost rpath) shows up on
# the push that caused it instead of on release day.
#
#   ./Scripts/check-bundle.sh [path/to/Tintpad.app] [path/to/Tintpad.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-.build/release/Tintpad.app}"
DMG="${2:-.build/release/Tintpad.dmg}"
C="$APP/Contents"
ERRORS=0
fail() { echo "  ✗ $*"; ERRORS=$((ERRORS + 1)); }
pass() { echo "  ✓ $*"; }
need() { # PATH DESCRIPTION
  if [[ -e "$1" ]]; then pass "$2"; else fail "$2 (missing ${1#"$APP"/})"; fi
}

echo "▸ Checking ${APP}"
[[ -d "$APP" ]] || { echo "✗ ${APP} does not exist, run ./Scripts/package.sh first"; exit 1; }

need "$C/Info.plist" "Info.plist"
if plutil -lint -s "$C/Info.plist"; then pass "Info.plist parses"; else fail "Info.plist does not parse"; fi
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion CFBundleExecutable SUFeedURL SUPublicEDKey; do
  v="$(/usr/libexec/PlistBuddy -c "Print :${key}" "$C/Info.plist" 2>/dev/null || true)"
  if [[ -n "$v" ]]; then pass "${key} = ${v}"; else fail "Info.plist has no ${key}"; fi
done
if cmp -s "$C/Info.plist" Resources/Info.plist; then pass "Info.plist is Resources/Info.plist"; else fail "Info.plist differs from Resources/Info.plist"; fi

EXE="$C/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$C/Info.plist" 2>/dev/null || echo Tintpad)"
if [[ -x "$EXE" ]]; then pass "executable ${EXE##*/}"; else fail "no executable at ${EXE#"$APP"/}"; fi
need "$C/Resources/Tintpad.icns" "app icon"

# SwiftPM resource bundles sit next to the executable, where Bundle.module
# looks for them. The app's own and KeyboardShortcuts' must both be there.
for b in Tintpad_Tintpad KeyboardShortcuts_KeyboardShortcuts; do
  need "$C/MacOS/${b}.bundle" "resource bundle ${b}"
done
for b in .build/release/*.bundle; do
  [[ -d "$b" ]] || continue
  need "$C/MacOS/$(basename "$b")" "built bundle $(basename "$b") was copied in"
done

FW="$C/Frameworks/Sparkle.framework"
need "$FW/Versions/B/Sparkle" "Sparkle.framework binary"
need "$FW/Versions/B/Autoupdate" "Sparkle Autoupdate"
need "$FW/Versions/B/Updater.app" "Sparkle Updater.app"
need "$FW/Versions/B/XPCServices/Installer.xpc" "Sparkle Installer.xpc"
need "$FW/Versions/B/XPCServices/Downloader.xpc" "Sparkle Downloader.xpc"

if [[ -x "$EXE" ]]; then
  if otool -L "$EXE" | grep -q '@rpath/Sparkle.framework'; then pass "links Sparkle through @rpath"; else fail "does not link @rpath/Sparkle.framework"; fi
  if otool -l "$EXE" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks'; then
    pass "rpath @executable_path/../Frameworks"
  else
    fail "rpath @executable_path/../Frameworks is missing, Sparkle will not load"
  fi
fi

if [[ -f "$DMG" ]]; then
  if hdiutil imageinfo "$DMG" >/dev/null 2>&1; then pass "DMG ${DMG} is a readable image"; else fail "DMG ${DMG} is not a readable image"; fi
else
  fail "no DMG at ${DMG}"
fi

echo
if [[ "$ERRORS" -gt 0 ]]; then echo "✗ Bundle check failed with ${ERRORS} error(s)."; exit 1; fi
echo "✓ Bundle check passed."
