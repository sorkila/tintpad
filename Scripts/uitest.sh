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
REPO="/tmp/tintpad-uitest"
KEY=$(grep -A1 "Working sample Pro key" secrets/license-private-key.txt 2>/dev/null | tail -1)

[ -d "$APP" ] || { echo "Build first: ./Scripts/package.sh"; exit 1; }

restore() {
  pkill -x Tintpad 2>/dev/null
  [ -f "$BK" ] && cp "$BK" "$STORE" && rm -f "$BK"
  rm -rf "$REPO"; rm -f /tmp/tp_A /tmp/tp_B
  echo "↩︎ real store restored"
}
trap restore EXIT

# --- set up controlled test store ---
cp "$STORE" "$BK"
rm -rf "$REPO"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" commit -q --allow-empty -m init
python3 - "$STORE" "$KEY" <<'PY'
import json, sys, uuid
store, key = sys.argv[1], sys.argv[2]
def mode(n): return {"id": str(uuid.uuid4()), "name": n, "flags": "", "isDangerous": False, "description": ""}
def agent(n, cmd):
    d = mode("Default")
    return {"id": str(uuid.uuid4()), "name": n, "commandTemplate": cmd, "acceptsPrompt": True,
            "symbol": "terminal", "modes": [d], "defaultModeID": d["id"]}
a = agent("TestA", "touch /tmp/tp_A; echo a {prompt}")
b = agent("TestB", "touch /tmp/tp_B; echo b {prompt}")
r = {"id": str(uuid.uuid4()), "path": "/tmp/tintpad-uitest", "name": "tintpad-uitest",
     "addedVia": "manual", "frecencyScore": 0, "launchCount": 0, "pinned": True, "defaultAgentID": a["id"]}
json.dump({"version": 1, "repos": [r], "agents": [a, b], "prompts": [], "sessions": [],
           "settings": {"rootScanFolders": [], "tintAccent": "orange", "frecencyHalfLifeDays": 30,
                        "confirmDangerousModes": False, "appearance": "dark", "panelWidth": 640,
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

echo "▸ J1 first-summon default launch";   rm -f /tmp/tp_A; summon; k 36 ""; check "TestA launched"  "wait_marker /tmp/tp_A"; settle
echo "▸ J2 search filter + launch";        rm -f /tmp/tp_A; summon; type "uitest"; sleep 0.5; k 36 ""; check "filtered launch" "wait_marker /tmp/tp_A"; settle
echo "▸ J3 agent cycle (⇥) + launch";      rm -f /tmp/tp_B; summon; k 48 ""; sleep 0.5; k 36 ""; check "TestB via ⇥" "wait_marker /tmp/tp_B"; settle
echo "▸ J4 mode cycle (⇧⇥) + launch";      rm -f /tmp/tp_A; summon; k 48 "using {shift down}"; sleep 0.5; k 36 ""; check "⇧⇥ then launch" "wait_marker /tmp/tp_A"; settle
echo "▸ J5 inline prompt (⌘L)";            summon; cmd "l"; sleep 0.6; type "hello"; sleep 0.4; k 36 ""; sleep 2.5
check "prompt session recorded" "python3 -c \"import json;d=json.load(open('$STORE'));exit(0 if any(s.get('prompt')=='hello' for s in d['sessions']) else 1)\""; settle
echo "▸ J6 esc dismiss (no launch)";       rm -f /tmp/tp_A; summon; k 53 ""; sleep 1.2; check "esc → no launch" "[ ! -f /tmp/tp_A ]"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
