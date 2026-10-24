# Shared release helpers, sourced by release.sh, check-release.sh and
# test-release.sh. Pure functions: no secrets, no network, no git. Written for
# the bash 3.2 that ships with macOS (no mapfile, no associative arrays).

# plist_get PLIST KEY → the value, or nothing (non-zero) when the key is absent.
plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

# changelog_section FILE VERSION → the body under "## [VERSION]" up to the next
# "## " heading, without leading or trailing blank lines. Exits 1 when the
# section is missing or empty. Matches by string, not regex, so the dots in a
# version are literal and [0.4.1] never matches [0.4.10].
changelog_section() {
  awk -v want="## [$2]" '
    /^[ \t]*```/ { fenced = !fenced }
    !fenced && index($0, "## ") == 1 {
      if (inside) exit
      if (index($0, want) == 1) {
        rest = substr($0, length(want) + 1)
        if (rest == "" || rest ~ /^[ ,]/) { inside = 1; next }
      }
    }
    inside { lines[++n] = $0 }
    END {
      first = 1; while (first <= n && lines[first] ~ /^[ \t]*$/) first++
      last = n;  while (last >= first && lines[last] ~ /^[ \t]*$/) last--
      if (last < first) exit 1
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$1"
}

# changelog_date FILE VERSION → the YYYY-MM-DD on the "## [VERSION] - date" line.
changelog_date() {
  awk -v want="## [$2] - " '
    index($0, want) == 1 {
      d = substr($0, length(want) + 1)
      if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) { print substr(d, 1, 10); found = 1 }
      exit
    }
    END { exit (found ? 0 : 1) }
  ' "$1"
}

# appcast_latest FILE → "BUILD SHORTVERSION" of the item with the highest
# <sparkle:version> (Sparkle compares build numbers, so that is the one a
# client is offered). Exits 1 when the feed has no versioned item.
appcast_latest() {
  awk '
    /<item>/ { b = ""; s = "" }
    match($0, /<sparkle:version>[^<]*<\/sparkle:version>/) {
      b = substr($0, RSTART + 17, RLENGTH - 35)
    }
    match($0, /<sparkle:shortVersionString>[^<]*<\/sparkle:shortVersionString>/) {
      s = substr($0, RSTART + 28, RLENGTH - 57)
    }
    /<\/item>/ {
      if (b ~ /^[0-9]+$/ && (best == "" || b + 0 > best + 0)) { best = b; bestShort = s }
    }
    END { if (best == "") exit 1; print best " " bestShort }
  ' "$1"
}

# version_gt A B → success when dotted-numeric A is strictly greater than B.
version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      if ((x[i] + 0) > (y[i] + 0)) exit 0
      if ((x[i] + 0) < (y[i] + 0)) exit 1
    }
    exit 1
  }'
}

# is_semver V → success for X.Y.Z with numeric parts.
is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# find_sign_update → the path of Sparkle's sign_update in the SwiftPM
# artifacts, or nothing (non-zero) before the first build has fetched it. The
# known SwiftPM 6.x location first, then any other layout an older SwiftPM uses.
find_sign_update() {
  local known=".build/artifacts/sparkle/Sparkle/bin/sign_update" found
  if [[ -x "$known" ]]; then echo "$known"; return 0; fi
  found="$(find .build/artifacts -type f -name sign_update -perm -u+x 2>/dev/null | head -n 1)"
  [[ -n "$found" ]] || return 1
  echo "$found"
}

# parse_enclosure"sparkle:edSignature=\"…\" length=\"…\"" → "SIGNATURE LENGTH",
# the two attributes sign_update prints for an appcast enclosure. Exits 1 on
# anything else (a prompt, an error, an empty string).
parse_enclosure() {
  local re='^sparkle:edSignature="([A-Za-z0-9+/=]+)" length="([0-9]+)"$'
  [[ "$1" =~ $re ]] || return 1
  echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
}

# release_ready JSON SIZE SHA256 → success when JSON (from `gh release view
# TAG --json isDraft,assets`) is a published release whose Tintpad.dmg asset
# has SIZE bytes and, when GitHub reports a digest, that sha256. Otherwise it
# prints why and exits 1. release.sh writes no appcast pointing at a draft or
# at a DMG that is not the one it signed.
release_ready() {
  local verdict
  verdict="$(jq -r --argjson size "$2" --arg sha "sha256:$3" '
    if .isDraft != false then "the release is a draft, its download URL is a 404"
    else ([.assets[]? | select(.name == "Tintpad.dmg")] | first) as $a
      | if $a == null then "it has no Tintpad.dmg asset"
        elif $a.size != $size then "Tintpad.dmg is \($a.size) bytes on GitHub, the signed DMG is \($size)"
        elif ($a.digest // "") != "" and $a.digest != $sha then "Tintpad.dmg on GitHub is \($a.digest), the signed DMG is \($sha)"
        else "ok" end
    end' <<<"$1" 2>/dev/null)" || verdict="gh did not return release JSON"
  [[ "$verdict" == ok ]] && return 0
  echo "${verdict:-gh did not return release JSON}"
  return 1
}

# render_release_notes TEMPLATE CHANGES_FILE VERSION SHA256 → the GitHub
# release body. The template's {{CHANGES}} line is replaced by the CHANGELOG
# section with its headings demoted one level (they sit under "### New in")
# and its hard-wrapped lines joined, since GitHub renders a newline inside a
# release body as a line break. {{VERSION}} and {{SHA256}} are replaced
# anywhere. Replacement is by string, so nothing in the CHANGELOG text is read
# as a pattern.
render_release_notes() {
  awk -v changes="$2" -v version="$3" -v sha="$4" '
    function subst(s, key, val,    out, i) {
      out = ""
      while ((i = index(s, key)) > 0) {
        out = out substr(s, 1, i - 1) val
        s = substr(s, i + length(key))
      }
      return out s
    }
    function starts_block(s) { # a line that must stay on its own
      return s ~ /^[ \t]*$/ || s ~ /^#+ / || s ~ /^[ \t]*([-*+]|[0-9]+\.)[ \t]/ || s ~ /^[ \t]*(```|\|)/
    }
    $0 == "{{CHANGES}}" {
      held = 0; fenced = 0
      while ((getline line < changes) > 0) {
        if (line ~ /^[ \t]*```/) fenced = !fenced
        if (!fenced && line ~ /^#+ /) line = "#" line
        if (held && !fenced && !starts_block(line) && pending !~ /^#+ / && pending !~ /^[ \t]*(```|\||$)/) {
          sub(/^[ \t]+/, "", line)
          pending = pending " " line
          continue
        }
        if (held) print pending
        pending = line; held = 1
      }
      if (held) print pending
      close(changes)
      next
    }
    { print subst(subst($0, "{{VERSION}}", version), "{{SHA256}}", sha) }
  ' "$1"
}
