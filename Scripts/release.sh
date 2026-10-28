#!/usr/bin/env bash
# One-command release. Preflight → build, sign, notarize, DMG → Sparkle
# signature → GitHub Release → appcast → Homebrew cask.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="tintpad-notary" \
#   SPARKLE_ED_KEY_FILE="$HOME/.config/sparkle/ed25519.key" \
#   ./Scripts/release.sh [--dry-run] [--republish] [version]
#
# Version defaults to CFBundleShortVersionString. Before running: bump BOTH
# CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist, rename
# CHANGELOG.md's [Unreleased] to "## [X.Y.Z] - YYYY-MM-DD", commit and push.
# Scripts/check-release.sh checks all of that first.
#
#   --dry-run    preflight (a dirty tree only warns), render the release notes,
#                show the signing path and the appcast item, then stop. Needs no
#                credentials and builds nothing.
#   --republish  the GitHub release already exists, published or left as a
#                draft (a re-run after a failure past `gh release create`).
#                Rebuilds and re-notarizes, so the DMG, its signature and its
#                sha256 all change: the DMG and notes are replaced on the
#                release, which is published, and the appcast and cask are
#                written fresh and must be committed again.
#
# Sparkle signing: with SPARKLE_ED_KEY_FILE set, sign_update reads the private
# key from that file and never touches the keychain, so the run is headless.
# Unset, it falls back to the login keychain, which shows a GUI approval prompt
# (run from a real terminal and click Allow). docs/RELEASE.md has the one-time
# export. The signature is checked against SUPublicEDKey before anything is
# published, so a wrong key stops the release instead of every user's updater.
#
# Prereqs (one-time): `xcrun notarytool store-credentials tintpad-notary …`
# and `gh auth login`.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=Scripts/release-lib.sh
. Scripts/release-lib.sh

DRY_RUN=0 REPUBLISH=0 VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --republish) REPUBLISH=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "release: unknown option $1" >&2; exit 2 ;;
    *) VERSION="$1" ;;
  esac
  shift
done

PLIST="Resources/Info.plist"
VERSION="${VERSION:-$(plist_get "$PLIST" CFBundleShortVersionString)}"
BUILD="$(plist_get "$PLIST" CFBundleVersion)"
PUBLIC_ED_KEY="$(plist_get "$PLIST" SUPublicEDKey)"
TAG="v${VERSION}"
REPO="sorkila/tintpad"
DMG=".build/release/Tintpad.dmg"
DL="https://github.com/${REPO}/releases/download/${TAG}/Tintpad.dmg"

die() { echo "✗ $*" >&2; exit 1; }

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "▸ Dry run for Tintpad ${VERSION} (${TAG}, build ${BUILD}). Nothing is built, signed or published."
else
  : "${SIGN_IDENTITY:?set SIGN_IDENTITY, \"Developer ID Application: Name (TEAMID)\"}"
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE, your notarytool keychain profile name}"
  command -v gh >/dev/null || die "gh is not installed (brew install gh, then gh auth login)"
  command -v jq >/dev/null || die "jq is not installed (it ships with macOS 15 and later, or brew install jq)"
  gh auth status -h github.com >/dev/null 2>&1 || die "gh is not logged in to github.com (gh auth login)"
  echo "▸ Releasing Tintpad ${VERSION} (${TAG}, build ${BUILD})"
fi
[[ -n "$PUBLIC_ED_KEY" ]] || die "Info.plist has no SUPublicEDKey, nothing could verify the update"

# 0. Preflight: versions against the live appcast, CHANGELOG, tree, tag.
PREFLIGHT=()
[[ "$DRY_RUN" -eq 1 ]] && PREFLIGHT+=(--allow-dirty)
[[ "$REPUBLISH" -eq 1 ]] && PREFLIGHT+=(--republish)
./Scripts/check-release.sh ${PREFLIGHT[@]+"${PREFLIGHT[@]}"} "$VERSION"

# Which key signs the appcast entry. An explicit key file must be usable, it
# never silently falls back to the keychain.
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  KEY_FILE="$SPARKLE_ED_KEY_FILE"
  [[ -f "$KEY_FILE" && -r "$KEY_FILE" ]] || die "SPARKLE_ED_KEY_FILE=${KEY_FILE} is not a readable file"
  KEY_DIR="$(cd "$(dirname "$KEY_FILE")" && pwd -P)"
  case "$KEY_DIR/" in
    "$(pwd -P)/"*)
      git check-ignore -q "$KEY_DIR/$(basename "$KEY_FILE")" \
        || die "the Sparkle key ${KEY_FILE} is inside the repo and not gitignored, move it out (see docs/RELEASE.md)"
      echo "  ! the Sparkle key is inside the repo (gitignored). This repo syncs through iCloud Drive, keep the key outside it."
      ;;
  esac
  MODE_BITS="$(stat -f '%Lp' "$KEY_FILE")"
  [[ "$MODE_BITS" == 600 || "$MODE_BITS" == 400 ]] \
    || echo "  ! ${KEY_FILE} is mode ${MODE_BITS}, run: chmod 600 \"${KEY_FILE}\""
  SIGN_ARGS=(--ed-key-file "$KEY_FILE")
  SIGN_DESC="key file ${KEY_FILE} (headless)"
else
  SIGN_ARGS=()
  SIGN_DESC="login keychain (SPARKLE_ED_KEY_FILE unset, macOS will ask to allow access)"
fi

# Release notes: the CHANGELOG section for this version in the template.
CHANGES_FILE="$(mktemp)"
NOTES_FILE="$(mktemp)"
trap 'rm -f "$CHANGES_FILE" "$NOTES_FILE"' EXIT
changelog_section CHANGELOG.md "$VERSION" > "$CHANGES_FILE" \
  || die "CHANGELOG.md has no section for ${VERSION}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  render_release_notes Scripts/release-notes.md "$CHANGES_FILE" "$VERSION" "<sha256 of the notarized DMG>" > "$NOTES_FILE"
  cat <<PLAN

Would run, in order:
  1. ./Scripts/package.sh            build, sign with SIGN_IDENTITY, notarize with NOTARY_PROFILE
  2. sign_update ${SIGN_ARGS[*]+${SIGN_ARGS[*]} }${DMG}
                                     signing key: ${SIGN_DESC}
     verify-ed25519.swift            against SUPublicEDKey ${PUBLIC_ED_KEY}
  3. gh release $([[ "$REPUBLISH" -eq 1 ]] && echo "upload --clobber + edit --draft=false" || echo "create ${TAG} --target $(git rev-parse --short HEAD)") -R ${REPO}
     gh release view --json          published, Tintpad.dmg the signed size, or stop here
  4. web/appcast.xml                 ${VERSION} (build ${BUILD}) → ${DL}
  5. Casks/tintpad.rb                version "${VERSION}", sha256 of the DMG
  6. web/index.html, sitemap.xml     stamped ${VERSION} / $(date +%F)

sign_update: $(find_sign_update || echo "not fetched yet (package.sh's build fetches it)")
SIGN_IDENTITY: $([[ -n "${SIGN_IDENTITY:-}" ]] && echo set || echo "unset, required for a real run")
NOTARY_PROFILE: $([[ -n "${NOTARY_PROFILE:-}" ]] && echo set || echo "unset, required for a real run")

Release notes (title "Tintpad ${VERSION}"):
----------------------------------------------------------------
PLAN
  cat "$NOTES_FILE"
  echo "----------------------------------------------------------------"
  echo "✓ Dry run done. Nothing was built, signed or published."
  exit 0
fi

# 1. Build, sign, notarize, staple, DMG.
./Scripts/package.sh
[[ -f "$DMG" ]] || die "package.sh did not produce ${DMG}"

# 1b. The signed app must idle before anything is public. 0.4.3 spun the main
# thread at launch, invisible to unit tests. check-idle.sh quits what it starts.
./Scripts/check-idle.sh .build/release/Tintpad.app || die "the built app does not idle, nothing was published"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
SIZE="$(stat -f '%z' "$DMG")"
echo "▸ DMG sha256: ${SHA} (${SIZE} bytes)"

# 2. Sparkle signature, before anything is public. A failure here leaves no
# GitHub release behind.
SIGN_UPDATE="$(find_sign_update)" || die "sign_update not found under .build/artifacts"
echo "▸ Signing the update with the ${SIGN_DESC}"
if [[ "${#SIGN_ARGS[@]}" -eq 0 ]]; then
  echo "  ┌──────────────────────────────────────────────────────────────────┐"
  echo "  │ macOS will ask to allow sign_update to use the Sparkle key.      │"
  echo "  │ Approve the keychain prompt, it is waiting for you.              │"
  echo "  │ Set SPARKLE_ED_KEY_FILE to skip it next time (docs/RELEASE.md).  │"
  echo "  └──────────────────────────────────────────────────────────────────┘"
fi
SIG="$("$SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$DMG")"   # → sparkle:edSignature="…" length="…"
ENCLOSURE="$(parse_enclosure "$SIG")" || die "sign_update printed something unexpected: ${SIG}"
ED_SIGNATURE="${ENCLOSURE% *}"
SIGNED_LENGTH="${ENCLOSURE#* }"
[[ "$SIGNED_LENGTH" == "$SIZE" ]] || die "signed length ${SIGNED_LENGTH} does not match the DMG's ${SIZE} bytes"
VERIFY=0
swift Scripts/verify-ed25519.swift "$PUBLIC_ED_KEY" "$ED_SIGNATURE" "$DMG" || VERIFY=$?
case "$VERIFY" in
  0) echo "▸ Signature verifies against SUPublicEDKey" ;;
  1) die "the signature does not verify against SUPublicEDKey in Info.plist, wrong Sparkle key? Nothing was published." ;;
  2) die "the signature or SUPublicEDKey is malformed (see the line above), not a key mismatch. Nothing was published." ;;
  *) die "verify-ed25519.swift failed to run (exit ${VERIFY}). Nothing was published." ;;
esac

# 3. GitHub Release with the DMG. Notes go via a file (a heredoc inside $(...)
# trips bash on the parens/backticks in the body). --target pins the tag to the
# commit this DMG was built from, not whatever main is on GitHub.
render_release_notes Scripts/release-notes.md "$CHANGES_FILE" "$VERSION" "$SHA" > "$NOTES_FILE"
# `gh release create` is draft, upload, publish in three calls, so a failure
# can leave a draft behind: --republish finishes it. --draft=false publishes a
# draft (a no-op on a published release), --target only applies while the tag
# does not exist yet.
if [[ "$REPUBLISH" -eq 1 ]]; then
  gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 || die "--republish, but there is no release or draft ${TAG}"
  gh release upload "$TAG" "$DMG" --clobber -R "$REPO"
  gh release edit "$TAG" -R "$REPO" --draft=false --target "$(git rev-parse HEAD)" \
    --title "Tintpad ${VERSION}" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" "$DMG" -R "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Tintpad ${VERSION}" --notes-file "$NOTES_FILE" \
    || die "gh release create failed. It may have left a draft ${TAG} on GitHub, re-run with --republish to finish it."
fi

# The appcast and cask point at the release's download URL, so they are written
# only once GitHub serves the DMG this run signed.
RELEASE_JSON="$(gh release view "$TAG" -R "$REPO" --json isDraft,assets)" \
  || die "could not read release ${TAG} back from GitHub. The appcast and cask were not written, re-run with --republish."
WHY="$(release_ready "$RELEASE_JSON" "$SIZE" "$SHA")" \
  || die "release ${TAG} is not ready: ${WHY}. The appcast and cask were not written, re-run with --republish."
echo "▸ Release ${TAG} is published with the signed Tintpad.dmg"

# 4. Sparkle appcast (auto-deploys via web/ → tintpad.com/appcast.xml).
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > web/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Tintpad</title>
    <link>https://tintpad.com/appcast.xml</link>
    <item>
      <title>${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${DL}" ${SIG} type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
[[ "$(appcast_latest web/appcast.xml)" == "${BUILD} ${VERSION}" ]] || die "web/appcast.xml did not come out as ${VERSION} (build ${BUILD})"
echo "▸ Wrote web/appcast.xml, commit and push to deploy it."

# 5. Homebrew cask.
sed -i '' -E "s/version \"[^\"]*\"/version \"${VERSION}\"/" Casks/tintpad.rb
sed -i '' -E "s/sha256 \"[0-9a-f]*\"/sha256 \"${SHA}\"/" Casks/tintpad.rb
grep -q "version \"${VERSION}\"" Casks/tintpad.rb && grep -q "sha256 \"${SHA}\"" Casks/tintpad.rb \
  || die "Casks/tintpad.rb was not rewritten, set version ${VERSION} and sha256 ${SHA} by hand"
echo "▸ Casks/tintpad.rb set to ${VERSION} / ${SHA}"

# ---- site stamp (self-contained: needs only a version, run from the repo root) ----
# Stamps the version line under the install command (<a class="ver">), the
# JSON-LD softwareVersion/dateModified, and the sitemap's lastmod. Ships with
# the appcast push, so the page always says when the last release was. Fails
# the release if any stamp did not land (markup changed under the seds).
stamp_site() {
  local version="$1" page="web/index.html" sitemap="web/sitemap.xml"
  local today month
  today="$(date +%F)"
  month="$(LC_ALL=C date +'%b %Y')"
  sed -i '' -E \
    -e "s/\"softwareVersion\": \"[^\"]*\"/\"softwareVersion\": \"${version}\"/" \
    -e "s/\"dateModified\": \"[^\"]*\"/\"dateModified\": \"${today}\"/" \
    -e "s/(class=\"ver\"[^>]*>)[^<]*/\1v${version}, ${month}/" \
    "$page"
  sed -i '' -E "s|<lastmod>[^<]*</lastmod>|<lastmod>${today}</lastmod>|" "$sitemap"
  if ! grep -qF "\"softwareVersion\": \"${version}\"" "$page" \
    || ! grep -qF "\"dateModified\": \"${today}\"" "$page" \
    || ! grep -qF ">v${version}, ${month}</a>" "$page" \
    || ! grep -qF "<lastmod>${today}</lastmod>" "$sitemap"; then
    echo "✗ site stamp missed, check web/index.html markup" >&2
    exit 1
  fi
  echo "▸ ${page} and ${sitemap} stamped ${version} / ${today}"
}
stamp_site "$VERSION"
# ---- end site stamp ----

cat <<DONE

✓ Release ${TAG} is up: https://github.com/${REPO}/releases/tag/${TAG}
Next:
  1. git add web/appcast.xml web/index.html web/sitemap.xml Casks/tintpad.rb && git commit -m "release ${VERSION}" && git push
     (push deploys appcast.xml and the stamped site to tintpad.com automatically)
  2. Copy Casks/tintpad.rb into the sorkila/homebrew-tap repo.
  3. Test: brew install --cask sorkila/tap/tintpad
DONE
