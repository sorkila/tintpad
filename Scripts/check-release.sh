#!/usr/bin/env bash
# Release preflight. Read-only: it never builds, signs, tags or publishes.
#
#   ./Scripts/check-release.sh [options] [VERSION]
#
# VERSION defaults to CFBundleShortVersionString in Resources/Info.plist.
#
# Release mode (the default, what release.sh runs first) asserts:
#   - Info.plist carries VERSION and an integer CFBundleVersion
#   - VERSION and CFBundleVersion are both above the newest item in the live
#     appcast (Sparkle compares the build number) and in web/appcast.xml
#   - CHANGELOG.md has a non-empty "## [VERSION] - YYYY-MM-DD" section
#   - the working tree is clean
#   - tag vVERSION exists neither locally nor on origin
#   - HEAD is on origin (gh release create --target needs the commit there)
#   - Casks/tintpad.rb has one version line and one sha256 line to rewrite
#
# CI mode (--ci) checks only what a commit can get wrong, so it passes on a
# resting main where Info.plist matches the live release:
#   - VERSION is X.Y.Z, CFBundleVersion is an integer
#   - CFBundleVersion never drops below the live build
#   - a version above the live one carries a higher build and a CHANGELOG section
#   - CHANGELOG.md has a section for the Info.plist version
#   - Casks/tintpad.rb is rewritable
# An unreachable live appcast is a warning in CI and an error in release mode.
#
# Options:
#   --ci                  CI mode, see above
#   --allow-dirty         a dirty tree is a warning, not an error
#   --allow-existing-tag  skip the tag check (release.sh --republish)
#   --offline             compare against web/appcast.xml only
#
# Env: APPCAST_URL overrides the feed URL (default: SUFeedURL in Info.plist).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=Scripts/release-lib.sh
. Scripts/release-lib.sh

MODE=release ALLOW_DIRTY=0 ALLOW_TAG=0 OFFLINE=0 VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci) MODE=ci ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --allow-existing-tag) ALLOW_TAG=1 ;;
    --offline) OFFLINE=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "check-release: unknown option $1" >&2; exit 2 ;;
    *) VERSION="$1" ;;
  esac
  shift
done

ERRORS=0
fail() { echo "  ✗ $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo "  ! $*"; }
pass() { echo "  ✓ $*"; }

PLIST="Resources/Info.plist"
PLIST_VERSION="$(plist_get "$PLIST" CFBundleShortVersionString || true)"
BUILD="$(plist_get "$PLIST" CFBundleVersion || true)"
VERSION="${VERSION:-$PLIST_VERSION}"
TAG="v${VERSION}"

echo "▸ Preflight for Tintpad ${VERSION} (build ${BUILD:-?}, ${MODE} mode)"

# --- Info.plist --------------------------------------------------------------
if ! is_semver "$VERSION"; then
  fail "version '${VERSION}' is not X.Y.Z"
elif [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  fail "Info.plist CFBundleShortVersionString is '${PLIST_VERSION}', expected '${VERSION}'"
else
  pass "Info.plist CFBundleShortVersionString ${VERSION}"
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
  fail "Info.plist CFBundleVersion '${BUILD}' is not an integer (Sparkle compares it as the build number)"
  BUILD=""
fi

# --- Appcast: live feed and the committed copy ---------------------------------
read_feed() { # FILE LABEL → sets FEED_BUILD FEED_VERSION
  local latest
  FEED_BUILD="" FEED_VERSION=""
  if latest="$(appcast_latest "$1")"; then
    FEED_BUILD="${latest%% *}" FEED_VERSION="${latest#* }"
    pass "$2 offers ${FEED_VERSION} (build ${FEED_BUILD})"
  else
    fail "$2 has no item with a numeric <sparkle:version>"
  fi
}

BASE_BUILD="" BASE_VERSION=""
consider() { # BUILD VERSION → keep the newest as the baseline
  [[ -n "$1" ]] || return 0
  if [[ -z "$BASE_BUILD" || "$1" -gt "$BASE_BUILD" ]]; then BASE_BUILD="$1" BASE_VERSION="$2"; fi
}

if [[ -f web/appcast.xml ]]; then
  read_feed web/appcast.xml "web/appcast.xml"
  COMMITTED_BUILD="$FEED_BUILD"
  consider "$FEED_BUILD" "$FEED_VERSION"
else
  fail "web/appcast.xml is missing"
  COMMITTED_BUILD=""
fi

if [[ "$OFFLINE" -eq 0 ]]; then
  URL="${APPCAST_URL:-$(plist_get "$PLIST" SUFeedURL || true)}"
  LIVE="$(mktemp)"
  trap 'rm -f "$LIVE"' EXIT
  if [[ -n "$URL" ]] && curl -fsSL --max-time 20 --retry 2 "$URL" -o "$LIVE"; then
    read_feed "$LIVE" "live appcast ${URL}"
    consider "$FEED_BUILD" "$FEED_VERSION"
    if [[ -n "$FEED_BUILD" && -n "$COMMITTED_BUILD" && "$FEED_BUILD" != "$COMMITTED_BUILD" ]]; then
      warn "web/appcast.xml (build ${COMMITTED_BUILD}) and the live feed (build ${FEED_BUILD}) disagree, a deploy may be pending"
    fi
  elif [[ "$MODE" == ci ]]; then
    warn "could not fetch the live appcast ${URL:-(no SUFeedURL)}, comparing against web/appcast.xml only"
  else
    fail "could not fetch the live appcast ${URL:-(no SUFeedURL)} (pass --offline to compare against web/appcast.xml only)"
  fi
fi

if [[ -n "$BASE_BUILD" && -n "$BUILD" ]] && is_semver "$VERSION"; then
  if [[ "$MODE" == release ]]; then
    if [[ "$BUILD" -le "$BASE_BUILD" ]]; then
      fail "CFBundleVersion ${BUILD} must be above the published build ${BASE_BUILD}, bump it in Info.plist"
    else
      pass "CFBundleVersion ${BUILD} > published build ${BASE_BUILD}"
    fi
    if ! version_gt "$VERSION" "$BASE_VERSION"; then
      fail "version ${VERSION} must be above the published ${BASE_VERSION}"
    else
      pass "version ${VERSION} > published ${BASE_VERSION}"
    fi
  else
    if [[ "$BUILD" -lt "$BASE_BUILD" ]]; then
      fail "CFBundleVersion ${BUILD} is below the published build ${BASE_BUILD}"
    elif [[ "$VERSION" == "$BASE_VERSION" ]]; then
      pass "Info.plist matches the published ${BASE_VERSION} (nothing pending)"
    elif version_gt "$VERSION" "$BASE_VERSION"; then
      if [[ "$BUILD" -le "$BASE_BUILD" ]]; then
        fail "version ${VERSION} is new but CFBundleVersion ${BUILD} is not above ${BASE_BUILD}, Sparkle would never offer it"
      else
        pass "pending release ${VERSION} (build ${BUILD}) is above the published ${BASE_VERSION} (build ${BASE_BUILD})"
      fi
    else
      fail "version ${VERSION} is below the published ${BASE_VERSION}"
    fi
  fi
fi

# --- CHANGELOG -----------------------------------------------------------------
if [[ ! -f CHANGELOG.md ]]; then
  fail "CHANGELOG.md is missing"
elif ! changelog_section CHANGELOG.md "$VERSION" >/dev/null; then
  fail "CHANGELOG.md has no non-empty '## [${VERSION}]' section (rename [Unreleased] to '## [${VERSION}] - $(date +%F)')"
elif ! DATE="$(changelog_date CHANGELOG.md "$VERSION")"; then
  fail "CHANGELOG.md '## [${VERSION}]' heading has no ' - YYYY-MM-DD' date"
else
  pass "CHANGELOG.md has a [${VERSION}] section dated ${DATE}"
  if [[ "$MODE" == release && "$DATE" != "$(date +%F)" ]]; then
    warn "the [${VERSION}] section is dated ${DATE}, today is $(date +%F)"
  fi
fi

# --- Homebrew cask -------------------------------------------------------------
CASK="Casks/tintpad.rb"
if [[ ! -f "$CASK" ]]; then
  fail "${CASK} is missing"
else
  nv="$(grep -cE '^[[:space:]]*version "[^"]*"' "$CASK" || true)"
  ns="$(grep -cE '^[[:space:]]*sha256 "[0-9a-f]{64}"' "$CASK" || true)"
  if [[ "$nv" -ne 1 || "$ns" -ne 1 ]]; then
    fail "${CASK} needs exactly one version line and one 64-hex sha256 line (found ${nv} and ${ns}), release.sh rewrites them"
  else
    pass "${CASK} is rewritable"
  fi
fi

# --- Git: clean tree, unused tag, HEAD on origin (release mode only) ---------------
if [[ "$MODE" == release ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    if [[ "$ALLOW_DIRTY" -eq 1 ]]; then warn "working tree is dirty"; else fail "working tree is dirty, commit or stash first"; fi
  else
    pass "working tree is clean"
  fi

  HAS_ORIGIN=0
  git remote get-url origin >/dev/null 2>&1 && HAS_ORIGIN=1

  if [[ "$ALLOW_TAG" -eq 1 ]]; then
    warn "tag check skipped (--allow-existing-tag)"
  elif git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    fail "tag ${TAG} already exists locally"
  elif [[ "$HAS_ORIGIN" -eq 1 ]]; then
    if REMOTE_TAG="$(git ls-remote --tags origin "refs/tags/${TAG}")"; then
      if [[ -n "$REMOTE_TAG" ]]; then fail "tag ${TAG} already exists on origin"; else pass "tag ${TAG} is unused"; fi
    else
      fail "could not list tags on origin"
    fi
  else
    warn "no origin remote, tag ${TAG} checked locally only"
  fi

  if [[ "$HAS_ORIGIN" -eq 1 ]]; then
    HEAD_SHA="$(git rev-parse HEAD)"
    ON_ORIGIN=0
    if HEADS="$(git ls-remote --heads origin)"; then
      for sha in $(printf '%s\n' "$HEADS" | cut -f1); do
        if [[ "$sha" == "$HEAD_SHA" ]] || { git cat-file -e "${sha}^{commit}" 2>/dev/null && git merge-base --is-ancestor HEAD "$sha"; }; then
          ON_ORIGIN=1; break
        fi
      done
      if [[ "$ON_ORIGIN" -eq 1 ]]; then pass "HEAD ${HEAD_SHA:0:7} is on origin"; else fail "HEAD ${HEAD_SHA:0:7} is not on origin, push it (or fetch) first, the release tag is created at this commit"; fi
    else
      fail "could not list branches on origin"
    fi
  fi
fi

echo
if [[ "$ERRORS" -gt 0 ]]; then
  echo "✗ Preflight failed with ${ERRORS} error(s)."
  exit 1
fi
echo "✓ Preflight passed."
