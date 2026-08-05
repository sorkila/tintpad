#!/bin/bash
# One-shot demo recording for the drop. Run on an UNLOCKED Mac, ideally the
# notched built-in display as primary. Seeds portfolio repos (backing up the
# real store), stages a dark backdrop, records the scripted TINTPAD_DEMO
# sequence, cuts every published asset, and restores the store.
#
# Needs: the current app installed (Scripts/dev-install.sh), ffmpeg, and
# Screen Recording permission for the terminal running this.
set -euo pipefail
cd "$(dirname "$0")/.."

STORE="$HOME/Library/Application Support/Tintpad/store.json"
WORK="$(mktemp -d)"
APP="/Applications/Tintpad.app/Contents/MacOS/Tintpad"

cleanup() {
  pkill -x Tintpad 2>/dev/null || true
  if [ -f "$WORK/store-backup.json" ]; then
    cp "$WORK/store-backup.json" "$STORE"
    open /Applications/Tintpad.app
  fi
}
trap cleanup EXIT

echo "▸ Backing up + seeding store…"
pkill -x Tintpad 2>/dev/null || true; sleep 1
cp "$STORE" "$WORK/store-backup.json"
python3 - "$STORE" <<'EOF'
import json, sys, uuid
path = sys.argv[1]
with open(path) as f: s = json.load(f)
claude = next(a['id'] for a in s['agents'] if 'Claude' in a['name'])
codex  = next((a['id'] for a in s['agents'] if 'Codex' in a['name']), claude)
names = [("Velm", claude, 9.0, False), ("Kuta", claude, 7.5, False),
         ("Lockpaw", codex, 6.2, False), ("Dela", claude, 5.1, False),
         ("Tintpad", claude, 4.0, False), ("Moonshot", codex, 3.1, False),
         ("Sidequest", claude, 2.2, False), ("Regretbox", claude, 1.4, False)]
s['repos'] = [{
    "addedVia": "manual", "frecencyScore": score,
    "id": str(uuid.uuid4()).upper(), "lastAgentID": agent,
    "launchCount": int(score), "name": name,
    "path": f"/Users/eriknielsen/Repositories/{name}", "pinned": pinned,
} for name, agent, score, pinned in names]
s['sessions'] = []
# Deterministic mode cycle for the red beat: the demo Claude has exactly
# Default and the dangerous mode (the user's store may carry legacy extras).
for a in s['agents']:
    if 'Claude' in a['name']:
        a['modes'] = [m for m in a['modes'] if m['name'] in ('Default', 'Skip permissions')]
with open(path, 'w') as f: json.dump(s, f, indent=1)
EOF

echo "▸ Recording (14s)…"
screencapture -v -V 14 "$WORK/demo-raw.mov" & sleep 0.7
TINTPAD_DEMO=1 TINTPAD_SCREEN_PRIMARY=1 "$APP" & sleep 15.5
pkill -x Tintpad || true

echo "▸ Hero still…"
TINTPAD_SHOWCASE=1 TINTPAD_SCREEN_PRIMARY=1 "$APP" & sleep 3.5
screencapture -x "$WORK/hero-full.png"
pkill -x Tintpad || true
pkill -f demo-backdrop.swift || true

echo "▸ Cutting assets…"
# Screen is 3024x1964 (2x). The produced cut: crop the story band, then a
# zoompan camera with smoothstep easing — wide for the fall, a slow push-in
# while arrowing, a drift right into the chips for the red dwell at maximum
# zoom, and an eased pull back to wide so the loop point is calm. Deliberate
# zooms tied to real beats, never random punch-ins.
EASE='st(1,clip((ld(0)-2)/2.5,0,1));st(1,ld(1)*ld(1)*(3-2*ld(1)));st(2,clip((ld(0)-6.6)/2.4,0,1));st(2,ld(2)*ld(2)*(3-2*ld(2)));st(3,clip((ld(0)-11.2)/1.8,0,1));st(3,ld(3)*ld(3)*(3-2*ld(3)))'
Z="st(0,in/60);${EASE};1+0.18*ld(1)+0.27*ld(2)-0.45*ld(3)"
X="st(0,in/60);${EASE};st(4,1000+400*ld(2)-400*ld(3));clip(ld(4)-(iw/zoom)/2,0,iw-iw/zoom)"
Y="clip(150-(ih/zoom)/2,0,ih-ih/zoom)"
ffmpeg -y -i "$WORK/demo-raw.mov" \
  -vf "crop=1900:470:512:0,fps=60,zoompan=z='${Z}':x='${X}':y='${Y}':d=1:s=1600x396:fps=60" \
  -c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p -movflags +faststart -an \
  web/assets/demo.mp4
ffmpeg -y -ss 10.0 -i web/assets/demo.mp4 -frames:v 1 -q:v 3 web/assets/demo-poster.jpg
sips -c 440 1800 --cropOffset 0 612 "$WORK/hero-full.png" --out docs/assets/palette.png >/dev/null
sips -c 800 1600 --cropOffset 0 712 "$WORK/hero-full.png" --out "$WORK/og-crop.png" >/dev/null
sips -z 640 1280 "$WORK/og-crop.png" --out web/assets/og.png >/dev/null

echo "✓ Assets written: web/assets/demo.mp4, demo-poster.jpg, og.png, docs/assets/palette.png"
echo "  Review them, then: git add web/assets docs/assets && git commit && git push"
