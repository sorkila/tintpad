#!/usr/bin/env bash
# Simulated user tests: drive the real app with synthetic keystrokes and verify
# side effects. Uses a temporary test store (two "touch a marker" agents +
# Terminal.app handoff) so launches are safe and verifiable, then restores your
# real store. Requires: a release build (./Scripts/package.sh) and that the app
# is granted Accessibility (to send keystrokes) + Automation (to drive Terminal).
set -uo pipefail
cd "$(dirname "$0")/.."

APP=".build/release/Tintpad.app"
STORE="$HOME/Library/Application Support/Tintpad/store.json"
BK="/tmp/tp_uitest_store_backup.json"
# Two repos, so "type to filter" has something to filter *out*. The first is
# pinned and the second is not: pinned sorts ahead of everything in
# Frecency.ordered, so row 1 stays row 1 no matter which repo a journey
# launches (a launch bumps the score, and an unpinned winner would silently
# reorder the list under the next journey).
REPO="/tmp/tintpad-uitest"
REPO2="/tmp/tintpad-zzother"
MARKERS="/tmp/tp_A /tmp/tp_B /tmp/tp_A_flags /tmp/tp_B_flags"
KEY=$(grep -A1 "Working sample Pro key" secrets/license-private-key.txt 2>/dev/null | tail -1)

[ -d "$APP" ] || { echo "Build first: ./Scripts/package.sh"; exit 1; }

restore() {
  pkill -x Tintpad 2>/dev/null
  [ -f "$BK" ] && cp "$BK" "$STORE" && rm -f "$BK"
  rm -rf "$REPO" "$REPO2"; rm -f $MARKERS
  echo "↩︎ real store restored"
}
trap restore EXIT

# --- set up controlled test store ---
cp "$STORE" "$BK"
for d in "$REPO" "$REPO2"; do
  rm -rf "$d"; mkdir -p "$d"; git -C "$d" init -q; git -C "$d" commit -q --allow-empty -m init
done
python3 - "$STORE" "$KEY" <<'PY'
import json, sys, uuid
store, key = sys.argv[1], sys.argv[2]
def mode(n, flags="", dangerous=False):
    return {"id": str(uuid.uuid4()), "name": n, "flags": flags,
            "isDangerous": dangerous, "description": ""}
def agent(n, cmd, modes):
    return {"id": str(uuid.uuid4()), "name": n, "commandTemplate": cmd, "acceptsPrompt": True,
            "symbol": "terminal", "modes": modes, "defaultModeID": modes[0]["id"]}
# TestA carries a second, permission-skipping mode with flags the template
# actually passes through, so a mode-cycle journey can assert on the marker's
# *content* rather than on the mere fact that something launched.
a = agent("TestA", 'touch /tmp/tp_A; echo "[{mode}]" > /tmp/tp_A_flags',
          [mode("Default"), mode("Skip permissions", "--test-danger", True)])
b = agent("TestB", 'touch /tmp/tp_B; echo "[{mode}]" > /tmp/tp_B_flags',
          [mode("Default")])
def repo(path, name, agent_id, pinned):
    return {"id": str(uuid.uuid4()), "path": path, "name": name, "addedVia": "manual",
            "frecencyScore": 0, "launchCount": 0, "pinned": pinned, "defaultAgentID": agent_id}
# Row 1 is pinned and answers to TestA. Row 2 is unpinned, named so it can be
# reached by a query that matches nothing else, and answers to TestB, so a
# filtered launch proves *which* repo the filter selected.
r1 = repo("/tmp/tintpad-uitest", "tintpad-uitest", a["id"], True)
r2 = repo("/tmp/tintpad-zzother", "tintpad-zzother", b["id"], False)
json.dump({"version": 1, "repos": [r1, r2], "agents": [a, b], "prompts": [], "sessions": [],
           "settings": {"rootScanFolders": [], "frecencyHalfLifeDays": 30,
                        "confirmDangerousModes": False,
                        "alsoOpenEditor": False, "licenseKey": key, "hasOnboarded": True,
                        "preferredTerminalBundleID": "com.apple.Terminal"}}, open(store, "w"))
PY

pkill -x Tintpad 2>/dev/null; sleep 1
open "$APP"; sleep 2

k(){ osascript -e "tell application \"System Events\" to key code $1 $2" 2>/dev/null; }
cmd(){ osascript -e "tell application \"System Events\" to keystroke \"$1\" using command down" 2>/dev/null; }
type(){ osascript -e "tell application \"System Events\" to keystroke \"$1\"" 2>/dev/null; }
# Re-activate Tintpad (Terminal grabs focus after each launch) then summon.
summon(){ osascript -e 'tell application id "com.sorkila.tintpad" to activate' 2>/dev/null; sleep 0.4
          k 49 "using {command down, option down}"; sleep 1.4; }
wait_marker(){ for _ in $(seq 1 16); do [ -f "$1" ] && return 0; sleep 0.5; done; return 1; }
settle(){ sleep 1.4; }   # let the app hide / Terminal settle between journeys

PASS=0; FAIL=0
check(){ if eval "$2"; then echo "  ✓ $1"; PASS=$((PASS+1)); else echo "  ✗ $1"; FAIL=$((FAIL+1)); fi; }

echo "▸ J1 first-summon default launch";   rm -f $MARKERS; summon; k 36 ""; check "TestA launched"  "wait_marker /tmp/tp_A"; settle
# Types a query that matches ONLY row 2, and row 2 answers to a different
# agent, so the marker identifies which repo the filter actually selected.
# Landing on tp_A here would mean the query changed nothing.
echo "▸ J2 search filter selects the other repo"; rm -f $MARKERS; summon; type "zzother"; sleep 0.5; k 36 ""
check "filter reached row 2 (TestB)" "wait_marker /tmp/tp_B"
check "row 1 was NOT launched" "[ ! -f /tmp/tp_A ]"; settle
echo "▸ J3 agent cycle (⇥) + launch";      rm -f $MARKERS; summon; k 48 ""; sleep 0.5; k 36 ""; check "TestB via ⇥" "wait_marker /tmp/tp_B"; settle
# Asserts the marker's CONTENT: ⇧⇥ must move TestA off Default and onto the
# permission-skipping mode, and the launched command must carry its flags.
echo "▸ J4 mode cycle (⇧⇥) passes the new mode's flags"; rm -f $MARKERS; summon; k 48 "using {shift down}"; sleep 0.5; k 36 ""
check "launched" "wait_marker /tmp/tp_A_flags"
check "flags are the cycled mode's" "grep -q -- '--test-danger' /tmp/tp_A_flags"; settle
echo "▸ J5 inline prompt (⌘L)";            summon; cmd "l"; sleep 0.6; type "hello"; sleep 0.4; k 36 ""; sleep 2.5
check "prompt session recorded" "python3 -c \"import json;d=json.load(open('$STORE'));exit(0 if any(s.get('prompt')=='hello' for s in d['sessions']) else 1)\""; settle
echo "▸ J6 esc dismiss (no launch)";       rm -f /tmp/tp_A; summon; k 53 ""; sleep 1.2; check "esc → no launch" "[ ! -f /tmp/tp_A ]"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
