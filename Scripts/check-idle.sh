#!/usr/bin/env bash
# Launch a built Tintpad.app, check it idles, and always quit it again.
# 0.4.3 pinned the main thread at launch, a scene loop no unit test can see,
# so release.sh runs this on the signed app before anything is published.
#
# A copy left running after a manual check once outlived its own bundle (the
# .build folder was deleted under it) and kept answering the hotkey for days,
# bringing Ghostty forward but typing nothing. So this script owns the copy it
# launches: it quits it on every exit path, and it hands the hotkey back to
# whatever Tintpad was running before (the single-instance guard means only
# one can run, so that one is quit first and relaunched after).
#
#   ./Scripts/check-idle.sh [path/to/Tintpad.app]
#   IDLE_SETTLE=5 IDLE_MAX_CPU=15   seconds to settle, average %CPU allowed
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-.build/release/Tintpad.app}"
BIN="$APP/Contents/MacOS/Tintpad"
SETTLE="${IDLE_SETTLE:-5}"
MAX_CPU="${IDLE_MAX_CPU:-15}"
[[ -x "$BIN" ]] || { echo "✗ ${BIN} does not exist, run ./Scripts/package.sh first" >&2; exit 1; }

quit_pid() { # PID: SIGTERM, then SIGKILL after ~5s (a spinning app may not answer)
  kill -TERM "$1" 2>/dev/null || return 0
  for _ in $(seq 1 25); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
  kill -KILL "$1" 2>/dev/null || true
}

# Whatever Tintpad is running now, quit it and remember where it came from.
PREVIOUS=""
for pid in $(pgrep -x Tintpad || true); do
  exe="$(ps -o comm= -p "$pid" || true)"
  PREVIOUS="${exe%/Contents/MacOS/Tintpad}"
  echo "▸ Quitting the running Tintpad (pid ${pid}, ${PREVIOUS})"
  quit_pid "$pid"
done

TEST_PID=""
cleanup() {
  [[ -n "$TEST_PID" ]] && quit_pid "$TEST_PID"
  if [[ -n "$PREVIOUS" ]]; then
    if [[ -d "$PREVIOUS" ]]; then
      echo "▸ Relaunching ${PREVIOUS}"
      open "$PREVIOUS" || echo "  ✗ could not relaunch it, open it by hand"
    else
      echo "  ! the Tintpad that was running came from ${PREVIOUS}, which no longer exists, open the installed one by hand"
    fi
  fi
}
trap cleanup EXIT

echo "▸ Launching ${APP}"
"$BIN" >/dev/null 2>&1 &
TEST_PID=$!
disown "$TEST_PID"   # no "Terminated" job notice when cleanup quits it
sleep "$SETTLE"
kill -0 "$TEST_PID" 2>/dev/null || { echo "✗ Tintpad exited within ${SETTLE}s of launch" >&2; TEST_PID=""; exit 1; }

# ps reports a decaying average, so take a few samples a second apart.
SAMPLES=""
for _ in 1 2 3 4 5; do
  SAMPLES+="$(ps -o %cpu= -p "$TEST_PID") "
  sleep 1
done
AVG="$(echo "$SAMPLES" | awk '{ for (i = 1; i <= NF; i++) s += $i; printf "%.1f", s / NF }')"
if awk -v a="$AVG" -v m="$MAX_CPU" 'BEGIN { exit !(a > m) }'; then
  echo "✗ Tintpad is not idle: ${AVG}% CPU on average (samples: ${SAMPLES% }), the limit is ${MAX_CPU}%" >&2
  exit 1
fi
echo "✓ Tintpad idles: ${AVG}% CPU on average after ${SETTLE}s"
