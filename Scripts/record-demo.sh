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
# Frame furniture, rendered by a tiny stdlib PNG writer: an anti-aliased
# notch tab (1.5px feathered corners) and a bezel-shadow gradient for the
# top edge, so the frame reads as hardware, not as a crop.
python3 - "$WORK/notch.png" <<'EOF'
import math, struct, sys, zlib
# Pure black tab, 3x3 supersampled edges, shadow given room to breathe —
# margins sized so the falloff ends inside the canvas, never boxed.
W, H = 360, 48
CX, HW, TH, R = W / 2, 160, 24, 10
def sd(px, py):
    qx = max(abs(px - CX) - (HW - R), 0)
    qy = max(py - (TH - R), 0)
    return math.hypot(qx, qy) - R
rows = []
for y in range(H):
    row = bytearray([0])
    for x in range(W):
        acc = 0.0
        for sy in (-0.33, 0.0, 0.33):
            for sx in (-0.33, 0.0, 0.33):
                d = sd(x + sx, y + sy)
                fill = max(0.0, min(1.0, (0.5 - d) / 1.0))
                shadow = 0.30 * (1 - min(max(d, 0) / 14, 1)) ** 2 if d > 0 else 0.0
                acc += max(fill, shadow)
        row += bytes([0, 0, 0, int(255 * acc / 9)])
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

# One continuous camera, the Motion way: four held framings — wide
# (arrival), medium (choosing), tight (the contract), wide (rest) —
# connected by fast quintic-eased dollies (0.45s), each timed to coincide
# with an on-screen action so motion masks motion. 3x oversampling keeps
# every move sub-pixel. The notch tab is bezel-fixed and fades out while
# the camera is committed to the close framings; a bezel-shadow gradient
# holds the top edge together.
QUINT='st(1,clip((ld(0)-2.5)/0.45,0,1));st(1,ld(1)*ld(1)*ld(1)*(ld(1)*(ld(1)*6-15)+10));st(2,clip((ld(0)-5.0)/0.45,0,1));st(2,ld(2)*ld(2)*ld(2)*(ld(2)*(ld(2)*6-15)+10));st(3,clip((ld(0)-10.0)/0.5,0,1));st(3,ld(3)*ld(3)*ld(3)*(ld(3)*(ld(3)*6-15)+10))'
Z="st(0,in/60);${QUINT};1+0.25*ld(1)+0.37*ld(2)-0.62*ld(3)"
X="st(0,in/60);${QUINT};st(4,(900-100*ld(1)+420*ld(2)-320*ld(3))*3);clip(ld(4)-(iw/zoom)/2,0,iw-iw/zoom)"
Y="st(0,in/60);${QUINT};st(5,(223-45*ld(1)-41*ld(2)+86*ld(3))*3);clip(ld(5)-(ih/zoom)/2,0,ih-ih/zoom)"
ffmpeg -y -i "$WORK/demo-raw.mov" -i "$WORK/notch.png" -filter_complex "\
[0:v]crop=1800:446:612:78,fps=60,trim=0.9:12.9,setpts=PTS-STARTPTS,scale=5400:-2,\
zoompan=z='${Z}':x='${X}':y='${Y}':d=1:s=1600x396:fps=60[cam];\
[1:v]loop=loop=720:size=1:start=0,fps=60,format=rgba[tab];\
[cam][tab]overlay=620:0:shortest=1[out]" -map "[out]" \
  -c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p -movflags +faststart -an \
  web/assets/demo.mp4
ffmpeg -y -ss 8.2 -i web/assets/demo.mp4 -frames:v 1 -q:v 3 web/assets/demo-poster.jpg
sips -c 446 1800 --cropOffset 78 612 "$WORK/hero-full.png" --out docs/assets/palette.png >/dev/null
sips -c 800 1600 --cropOffset 78 712 "$WORK/hero-full.png" --out "$WORK/og-crop.png" >/dev/null
sips -z 640 1280 "$WORK/og-crop.png" --out web/assets/og.png >/dev/null

echo "✓ Assets written: web/assets/demo.mp4, demo-poster.jpg, og.png, docs/assets/palette.png"
echo "  Review them, then: git add web/assets docs/assets && git commit && git push"
