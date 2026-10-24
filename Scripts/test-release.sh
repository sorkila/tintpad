#!/usr/bin/env bash
# Self-test for the release scripts. Offline, no secrets, no keychain: every
# check runs against fixtures in a temp dir or reads the real CHANGELOG.
#
#   ./Scripts/test-release.sh
#
# The Sparkle known-answer test runs only when sign_update has been fetched
# (any swift build does that). It signs with the public RFC 8032 test seed
# through --ed-key-file, never the release key.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
# shellcheck source=Scripts/release-lib.sh
. Scripts/release-lib.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSED=0 FAILED=0
ok()  { PASSED=$((PASSED + 1)); echo "  ✓ $*"; }
bad() { FAILED=$((FAILED + 1)); echo "  ✗ $*"; }
expect() { # DESCRIPTION COMMAND… → passes when COMMAND succeeds
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
expect_not() { # DESCRIPTION COMMAND… → passes when COMMAND fails
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi
}
expect_eq() { # DESCRIPTION ACTUAL EXPECTED
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi
}

echo "▸ Syntax"
for s in Scripts/*.sh; do expect "bash -n ${s}" bash -n "$s"; done

echo "▸ CHANGELOG extraction (the real CHANGELOG.md)"
expect_not "a missing version has no section" changelog_section CHANGELOG.md 9.9.9
expect "0.4.1 has a section" changelog_section CHANGELOG.md 0.4.1
s041="$(changelog_section CHANGELOG.md 0.4.1)"
expect_eq "0.4.1 starts at its first subheading" "$(printf '%s\n' "$s041" | head -1)" "### Changed"
expect_not "0.4.1 stops before the 0.4.0 heading" grep -q '^## ' <<<"$s041"
expect_eq "0.4.1 has no trailing blank line" "$(printf '%s\n' "$s041" | tail -1 | grep -c '^[[:space:]]*$' || true)" "0"
expect "0.1.0 matches its comma heading" changelog_section CHANGELOG.md 0.1.0
expect_eq "0.4.1 date" "$(changelog_date CHANGELOG.md 0.4.1)" "2026-09-17"
expect_not "0.1.0 has no date" changelog_date CHANGELOG.md 0.1.0

cat > "$TMP/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.4.10] - 2026-12-01
- ten

## [0.4.1] - 2026-09-17

A paragraph that
wraps.

### Fixed
- a bullet that
  wraps twice
  over three lines
  - a nested item
- one & two \ $HOME

## [0.4.0] - 2026-09-16

## [0.3.9] - 2026-09-01
- nine
EOF
expect_eq "0.4.1 is not confused with 0.4.10" "$(changelog_section "$TMP/CHANGELOG.md" 0.4.1 | tail -1)" '- one & two \ $HOME'
expect_eq "0.4.10 is its own section" "$(changelog_section "$TMP/CHANGELOG.md" 0.4.10)" "- ten"
expect_not "an empty section counts as missing" changelog_section "$TMP/CHANGELOG.md" 0.4.0
expect_not "an empty [Unreleased] counts as missing" changelog_section "$TMP/CHANGELOG.md" Unreleased

echo "▸ Appcast parsing"
expect "web/appcast.xml has a latest item" appcast_latest web/appcast.xml
expect "web/appcast.xml latest is 'BUILD X.Y.Z'" grep -Eq '^[0-9]+ [0-9]+\.[0-9]+\.[0-9]+$' <<<"$(appcast_latest web/appcast.xml)"
cat > "$TMP/feed.xml" <<'EOF'
<rss><channel>
  <item>
    <sparkle:version>13</sparkle:version>
    <sparkle:shortVersionString>0.4.2</sparkle:shortVersionString>
  </item>
  <item>
    <sparkle:version>9</sparkle:version>
    <sparkle:shortVersionString>0.3.9</sparkle:shortVersionString>
  </item>
</channel></rss>
EOF
expect_eq "the highest build wins, wherever it sits" "$(appcast_latest "$TMP/feed.xml")" "13 0.4.2"
printf '<rss><channel></channel></rss>\n' > "$TMP/empty.xml"
expect_not "a feed with no item fails" appcast_latest "$TMP/empty.xml"

echo "▸ Version order"
expect "0.4.2 > 0.4.1" version_gt 0.4.2 0.4.1
expect "0.4.10 > 0.4.9" version_gt 0.4.10 0.4.9
expect "1.0.0 > 0.99.99" version_gt 1.0.0 0.99.99
expect_not "0.4.1 > 0.4.1 is false" version_gt 0.4.1 0.4.1
expect_not "0.4.1 > 0.4.2 is false" version_gt 0.4.1 0.4.2

echo "▸ Release notes"
changelog_section "$TMP/CHANGELOG.md" 0.4.1 > "$TMP/changes.md"
render_release_notes Scripts/release-notes.md "$TMP/changes.md" 0.4.1 "$(printf 'a%.0s' {1..64})" > "$TMP/notes.md"
expect "the version lands in the title" grep -q '^### New in 0.4.1$' "$TMP/notes.md"
expect "CHANGELOG headings are demoted under it" grep -q '^#### Fixed$' "$TMP/notes.md"
expect "CHANGELOG text is copied verbatim" grep -qF -- '- one & two \ $HOME' "$TMP/notes.md"
expect "a wrapped bullet is joined into one line" grep -qxF -- '- a bullet that wraps twice over three lines' "$TMP/notes.md"
expect "a nested item stays its own line" grep -qxF -- '  - a nested item' "$TMP/notes.md"
expect "a wrapped paragraph is joined" grep -qxF -- 'A paragraph that wraps.' "$TMP/notes.md"
expect "the heading is not joined to its first bullet" grep -qxF -- '#### Fixed' "$TMP/notes.md"
changelog_section CHANGELOG.md 0.4.1 > "$TMP/real-changes.md"
render_release_notes Scripts/release-notes.md "$TMP/real-changes.md" 0.4.1 "$(printf 'a%.0s' {1..64})" > "$TMP/real-notes.md"
expect_eq "the real 0.4.1 bullets are one line each" "$(grep -c '^- \*\*' "$TMP/real-notes.md")" "$(grep -c '^- ' "$TMP/real-changes.md")"
expect_not "no line of the real 0.4.1 notes is a stray continuation" grep -q '^  [a-z]' "$TMP/real-notes.md"
expect "the sha256 is stamped" grep -q "sha256 \`$(printf 'a%.0s' {1..64})\`" "$TMP/notes.md"
expect_not "no placeholder survives" grep -q '{{' "$TMP/notes.md"

echo "▸ Ed25519 verifier (RFC 8032 test 2)"
RFC_SEED="4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
RFC_PUB="3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
RFC_SIG="92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
b64() { xxd -r -p <<<"$1" | base64; }
printf '\x72' > "$TMP/msg"
printf '\x73' > "$TMP/tampered"
expect "a valid signature verifies" swift Scripts/verify-ed25519.swift "$(b64 "$RFC_PUB")" "$(b64 "$RFC_SIG")" "$TMP/msg"
expect_not "a tampered file does not" swift Scripts/verify-ed25519.swift "$(b64 "$RFC_PUB")" "$(b64 "$RFC_SIG")" "$TMP/tampered"
expect_not "another key's signature fails against SUPublicEDKey" swift Scripts/verify-ed25519.swift \
  "$(plist_get Resources/Info.plist SUPublicEDKey)" "$(b64 "$RFC_SIG")" "$TMP/msg"

echo "▸ sign_update output parsing"
expect_eq "the enclosure attributes split into signature and length" \
  "$(parse_enclosure 'sparkle:edSignature="QUJD+/9=" length="4951114"')" "QUJD+/9= 4951114"
expect_not "anything else is refused" parse_enclosure 'Error: no key found in the keychain'
expect_not "an empty string is refused" parse_enclosure ''

if SIGN_UPDATE="$(find_sign_update)"; then
  echo "▸ sign_update --ed-key-file (known answer, ${SIGN_UPDATE})"
  (umask 077; b64 "$RFC_SEED" > "$TMP/test-seed")
  out="$("$SIGN_UPDATE" --ed-key-file "$TMP/test-seed" "$TMP/msg")"
  expect_eq "sign_update prints the enclosure attributes" "$out" "sparkle:edSignature=\"$(b64 "$RFC_SIG")\" length=\"1\""
  expect_eq "release.sh parses that output" "$(parse_enclosure "$out")" "$(b64 "$RFC_SIG") 1"
  expect_eq "sign_update -p prints the bare signature" "$("$SIGN_UPDATE" --ed-key-file "$TMP/test-seed" -p "$TMP/msg")" "$(b64 "$RFC_SIG")"
  expect_eq "the key on stdin (release.yml's path) signs the same" \
    "$(printf '%s' "$(b64 "$RFC_SEED")" | "$SIGN_UPDATE" --ed-key-file - "$TMP/msg")" "$out"
else
  echo "  - sign_update not fetched yet, skipping the known-answer test"
fi

echo "▸ check-release.sh (fixtures, --offline)"
fixture() { # VERSION BUILD FEED_VERSION FEED_BUILD → a fresh fixture repo in $TMP/fx
  rm -rf "$TMP/fx"; mkdir -p "$TMP/fx/Scripts" "$TMP/fx/Resources" "$TMP/fx/web" "$TMP/fx/Casks"
  cp Scripts/check-release.sh Scripts/release-lib.sh Scripts/release.sh Scripts/release-notes.md "$TMP/fx/Scripts/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $1" \
    -c "Add :CFBundleVersion string $2" \
    -c "Add :SUPublicEDKey string $(b64 "$RFC_PUB")" "$TMP/fx/Resources/Info.plist" >/dev/null
  cat > "$TMP/fx/web/appcast.xml" <<EOF
<rss><channel><item>
  <sparkle:version>$4</sparkle:version>
  <sparkle:shortVersionString>$3</sparkle:shortVersionString>
</item></channel></rss>
EOF
  printf '# Changelog\n\n## [%s] - %s\n- a change\n\n## [%s] - 2026-01-01\n- an older change\n' \
    "$1" "$(date +%F)" "$3" > "$TMP/fx/CHANGELOG.md"
  printf 'cask "tintpad" do\n  version "%s"\n  sha256 "%s"\nend\n' "$3" "$(printf 'b%.0s' {1..64})" > "$TMP/fx/Casks/tintpad.rb"
}
check() { "$TMP/fx/Scripts/check-release.sh" --offline "$@"; }

fixture 0.4.1 12 0.4.1 12
expect "ci: a resting main passes" check --ci
fixture 0.4.2 13 0.4.1 12
expect "ci: a bumped version with a bumped build passes" check --ci
fixture 0.4.2 12 0.4.1 12
expect_not "ci: a new version without a build bump fails" check --ci
fixture 0.4.1 11 0.4.1 12
expect_not "ci: a build below the published one fails" check --ci
fixture 0.4.0 13 0.4.1 12
expect_not "ci: a version below the published one fails" check --ci
fixture 0.4.2 13 0.4.1 12
printf '# Changelog\n\n## [Unreleased]\n- a change\n' > "$TMP/fx/CHANGELOG.md"
expect_not "ci: a missing CHANGELOG section fails" check --ci
fixture 0.4.2 13 0.4.1 12
printf 'cask "tintpad" do\nend\n' > "$TMP/fx/Casks/tintpad.rb"
expect_not "ci: a cask without version/sha256 fails" check --ci
fixture 0.4.2 abc 0.4.1 12
expect_not "ci: a non-integer build fails" check --ci

fixture 0.4.2 13 0.4.1 12
(cd "$TMP/fx" && git init -q && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm fixture)
expect "release: a clean, bumped, untagged tree passes" check
expect_not "release: a version argument that disagrees with Info.plist fails" check 0.4.3
touch "$TMP/fx/stray"
expect_not "release: a dirty tree fails" check
expect "release: --allow-dirty lets it through" check --allow-dirty
rm "$TMP/fx/stray"
(cd "$TMP/fx" && git -c tag.gpgSign=false tag v0.4.2)
expect_not "release: an existing tag fails" check
expect "release: --allow-existing-tag lets it through" check --allow-existing-tag
fixture 0.4.1 12 0.4.1 12
(cd "$TMP/fx" && git init -q && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm fixture)
expect_not "release: the already published version fails" check

echo "▸ release.sh --dry-run (fixture, feed via file://)"
fixture 0.4.2 13 0.4.1 12
printf '/secrets/\n' > "$TMP/fx/.gitignore"
(cd "$TMP/fx" && git init -q && git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm fixture)
export APPCAST_URL="file://$TMP/fx/web/appcast.xml"
dry() { env -u SIGN_IDENTITY -u NOTARY_PROFILE "$@" "$TMP/fx/Scripts/release.sh" --dry-run; }
out="$(dry env -u SPARKLE_ED_KEY_FILE 2>&1)" && ok "a dry run passes without credentials" || bad "a dry run passes without credentials: $out"
expect "it renders the notes from the CHANGELOG" grep -q '^### New in 0.4.2$' <<<"$out"
expect "it names the keychain fallback" grep -q 'login keychain' <<<"$out"
expect "it plans gh release create at HEAD" grep -q "create v0.4.2 --target $(cd "$TMP/fx" && git rev-parse --short HEAD)" <<<"$out"
printf 'not a key\n' > "$TMP/outside.key"; chmod 600 "$TMP/outside.key"
out="$(dry env SPARKLE_ED_KEY_FILE="$TMP/outside.key" 2>&1)" || true
expect "a key file outside the repo signs headless" grep -q "key file $TMP/outside.key (headless)" <<<"$out"
expect_not "a mode 600 key file draws no warning" grep -q 'chmod 600' <<<"$out"
chmod 644 "$TMP/outside.key"
expect "a world-readable key file is called out" grep -q 'chmod 600' <<<"$(dry env SPARKLE_ED_KEY_FILE="$TMP/outside.key" 2>&1)"
expect_not "a missing key file stops the run" dry env SPARKLE_ED_KEY_FILE="$TMP/nope.key"
printf 'not a key\n' > "$TMP/fx/stray.key"
expect_not "a key file in the repo and not ignored stops the run" dry env SPARKLE_ED_KEY_FILE="$TMP/fx/stray.key"
rm "$TMP/fx/stray.key"
mkdir -p "$TMP/fx/secrets"; printf 'not a key\n' > "$TMP/fx/secrets/ed.key"
expect "a gitignored key file in the repo is allowed" dry env SPARKLE_ED_KEY_FILE="$TMP/fx/secrets/ed.key"
unset APPCAST_URL

cd "$ROOT"
echo
echo "${PASSED} passed, ${FAILED} failed"
[[ "$FAILED" -eq 0 ]]
