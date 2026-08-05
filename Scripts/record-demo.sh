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

echo "▸ Recording (13s)…"
screencapture -v -V 13 "$WORK/demo-raw.mov" & sleep 0.7
TINTPAD_DEMO=1 TINTPAD_SCREEN_PRIMARY=1 "$APP" & sleep 14.5
pkill -x Tintpad || true

echo "▸ Hero still…"
TINTPAD_SHOWCASE=1 TINTPAD_SCREEN_PRIMARY=1 "$APP" & sleep 3.5
screencapture -x "$WORK/hero-full.png"
pkill -x Tintpad || true
pkill -f demo-backdrop.swift || true

echo "▸ Cutting assets…"
# A crisp notch matte with real rounded bottom corners — drawbox can't
# round, so a tiny stdlib PNG writer builds it once per run.
python3 - "$WORK/notch.png" <<'EOF'
import struct, sys, zlib
W, H, R = 320, 24, 10
rows = []
for y in range(H):
    row = bytearray([0])
    for x in range(W):
        a = 255
        if y > H - R:
            dy = y - (H - R)
            for cx in (R, W - R):
                if (x < R and cx == R) or (x > W - R and cx == W - R):
                    import math
                    if math.hypot(x - (R if cx == R else W - R), dy) > R:
                        a = 0
        row += bytes([0, 0, 0, a])
    rows.append(bytes(row))
raw = b"".join(rows)
def chunk(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw))
png += chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
EOF

# The cut film: four shots, hard cuts, each landing just before an action.
#   S1 wide        — the fall out of the notch, micro push for life
#   S2 medium      — the selection walking the tokens (cut lands between chips)
#   S3 tight       — the chips: agent flip, then the red dwell (micro push)
#   S4 wide        — rest, the calm loop point
# The menu-bar text left and right is smeared away (boxblur) so the top of
# frame reads as hardware: blank bar, crisp black notch, the drop beneath it.
MASK="crop=1800:446:612:78,fps=60"
ffmpeg -y -i "$WORK/demo-raw.mov" -i "$WORK/notch.png" -filter_complex "\
[0:v]${MASK}[band];\
[1:v]split=2[n1][n4];\
[band]split=4[s1][s2][s3][s4];\
[s1]trim=0.9:3.4,setpts=PTS-STARTPTS,scale=5400:-2,zoompan=z='st(0,clip(in/150,0,1));st(0,ld(0)*ld(0)*(3-2*ld(0)));1+0.05*ld(0)':x='(iw-iw/zoom)/2':y=0:d=1:s=1600x396:fps=60[c1p];[c1p][n1]overlay=640:0[c1];\
[s2]trim=3.4:5.9,setpts=PTS-STARTPTS,crop=1440:357:80:0,scale=1600:396[c2];\
[s3]trim=5.9:10.9,setpts=PTS-STARTPTS,scale=5400:-2,zoompan=z='st(0,clip(in/300,0,1));st(0,ld(0)*ld(0)*(3-2*ld(0)));1.62+0.08*ld(0)':x='min(4350-(iw/zoom)/2,iw-iw/zoom)':y=0:d=1:s=1600x396:fps=60[c3];\
[s4]trim=10.9:12.9,setpts=PTS-STARTPTS,scale=1600:396[c4p];[c4p][n4]overlay=640:0[c4];\
[c1][c2][c3][c4]concat=n=4:v=1:a=0[out]" -map "[out]" \
  -c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p -movflags +faststart -an \
  web/assets/demo.mp4
ffmpeg -y -ss 8.2 -i web/assets/demo.mp4 -frames:v 1 -q:v 3 web/assets/demo-poster.jpg
sips -c 446 1800 --cropOffset 78 612 "$WORK/hero-full.png" --out docs/assets/palette.png >/dev/null
sips -c 800 1600 --cropOffset 78 712 "$WORK/hero-full.png" --out "$WORK/og-crop.png" >/dev/null
sips -z 640 1280 "$WORK/og-crop.png" --out web/assets/og.png >/dev/null

echo "✓ Assets written: web/assets/demo.mp4, demo-poster.jpg, og.png, docs/assets/palette.png"
echo "  Review them, then: git add web/assets docs/assets && git commit && git push"
