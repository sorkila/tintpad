#!/bin/bash
# One-shot demo recording for the drop. Run on an UNLOCKED Mac, ideally the
# notched built-in display as primary. Seeds portfolio repos (backing up the
# real store), stages a dark backdrop, records the scripted TINTPAD_DEMO
# sequence, cuts every published asset, and restores the store.
#
# Needs: the current app installed (Scripts/dev-install.sh), ffmpeg, Pillow
# (python3 -m pip install Pillow, for the keycap captions), and
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

echo "▸ Recording (16s)…"
screencapture -v -V 16 "$WORK/demo-raw.mov" & sleep 0.7
TINTPAD_DEMO=1 TINTPAD_SCREEN_PRIMARY=1 "$APP" & sleep 17
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
W, H = 360, 76
CX, HW, TH, R = W / 2, 160, 50, 10
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

# screencapture writes frames only when the screen changes, so the raw take
# ends at the last visible change, not at -V. tpad holds that last frame so
# the final framing has time to settle before the trim's end.
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
# Keystrokes, the keynote way: a keycap and a plain label under the drop, in
# time with each scripted beat (TINTPAD_DEMO in TintpadApp.swift), the cap
# lighting briefly on every press. Bezel-fixed like the notch tab, so the
# camera moves under them, and set low in the frame, below the tightest
# framing's drop. KEY_OFFSET maps the app's beat clock to film time
# (screencapture start latency and the trim), checked per take.
KEY_OFFSET="${KEY_OFFSET:-0.15}"
python3 - "$WORK" "$KEY_OFFSET" <<'PYKEYS'
import sys
from PIL import Image, ImageDraw, ImageFont
work, off = sys.argv[1], float(sys.argv[2])
SF = "/System/Library/Fonts/SFNS.ttf"
def font(size, weight):
    f = ImageFont.truetype(SF, size)
    # Axes: width, optical size, grade, weight. Normal width, text optics.
    f.set_variation_by_axes([100, size, 400, weight])
    return f
KEY, LABEL = font(30, 600), font(28, 420)
# One cap per key, the way Apple prints shortcuts: (caps, label, presses) in
# the app's beat seconds. SF has no tab arrow, so tab is spelled out.
GROUPS = [
    (["⌥", "⌘", "space"], "Summon", [0.45]),
    (["→"], "Choose a repo", [3.0, 3.7, 4.4]),
    (["tab"], "Switch agent", [5.4, 6.2]),
    (["⇧", "tab"], "Switch mode", [7.0, 9.6]),
]
H, PAD, CAPGAP, GAP, MINCAP = 56, 16, 8, 18, 56
def render(caps, label, lit):
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    widths = [max(MINCAP, int(probe.textlength(c, font=KEY) + 2 * PAD)) for c in caps]
    capsw = sum(widths) + CAPGAP * (len(caps) - 1)
    lw = probe.textlength(label, font=LABEL)
    im = Image.new("RGBA", (int(capsw + GAP + lw + 4), H + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    x = 0
    for c, w in zip(caps, widths):
        d.rounded_rectangle((x + 0.5, 0.5, x + w - 0.5, H - 0.5), radius=14,
                            fill=(255, 255, 255, 64 if lit else 24),
                            outline=(255, 255, 255, 120 if lit else 72), width=2)
        d.text((x + w / 2, H / 2), c, font=KEY, fill=(255, 255, 255, 245), anchor="mm")
        x += w + CAPGAP
    d.text((capsw + GAP, H / 2), label, font=LABEL, fill=(255, 255, 255, 160), anchor="lm")
    return im
inputs, chain, last = [], [], "[out]"
def still(path, start, fade_in, end, fade_out, tag):
    n = len(inputs) + 2  # after the raw take and the notch tab
    inputs.append(path)
    chain.append(f"[{n}:v]loop=loop=-1:size=1,fps=60,format=rgba,trim=0:12,"
                 f"fade=t=in:st={start:.2f}:d={fade_in}:alpha=1,"
                 f"fade=t=out:st={end:.2f}:d={fade_out}:alpha=1[{tag}]")
for i, (caps, label, presses) in enumerate(GROUPS):
    base, lit = render(caps, label, False), render(caps, label, True)
    base.save(f"{work}/key{i}.png")
    lit.save(f"{work}/key{i}lit.png")
    x, y = (1600 - base.width) // 2, 300
    start = presses[0] + off - 0.15
    # Never two captions at once: each leaves before the next arrives.
    end = presses[-1] + off + 1.1
    if i + 1 < len(GROUPS):
        end = min(end, GROUPS[i + 1][2][0] + off - 0.15 - 0.25)
    still(f"{work}/key{i}.png", start, 0.2, end, 0.25, f"k{i}")
    chain.append(f"{last}[k{i}]overlay={x}:{y}:shortest=1[o{i}]")
    last = f"[o{i}]"
    for j, t in enumerate(presses):
        still(f"{work}/key{i}lit.png", t + off, 0.04, t + off + 0.12, 0.2, f"p{i}{j}")
        chain.append(f"{last}[p{i}{j}]overlay={x}:{y}:shortest=1[q{i}{j}]")
        last = f"[q{i}{j}]"
open(f"{work}/keys.inputs", "w").write("\n".join(inputs) + "\n")
open(f"{work}/keys.filter", "w").write(";".join(chain) + f";{last}null[final]")
PYKEYS
KEY_INPUTS=()
while IFS= read -r f; do [ -n "$f" ] && KEY_INPUTS+=(-i "$f"); done < "$WORK/keys.inputs"
{
  printf '%s' "[0:v]crop=1800:406:612:48,pad=1800:446:0:40:color=black,tpad=stop_mode=clone:stop_duration=4,fps=60,trim=0.9:12.9,setpts=PTS-STARTPTS,scale=5400:-2,zoompan=z='${Z}':x='${X}':y='${Y}':d=1:s=1600x396:fps=60[cam];[1:v]loop=loop=720:size=1:start=0,fps=60,format=rgba[tab];[cam][tab]overlay=620:0:shortest=1[out];"
  cat "$WORK/keys.filter"
} > "$WORK/film.filter"
ffmpeg -y -i "$WORK/demo-raw.mov" -i "$WORK/notch.png" "${KEY_INPUTS[@]}" \
  -filter_complex_script "$WORK/film.filter" -map "[final]" \
  -c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p -movflags +faststart -an \
  web/assets/demo.mp4
ffmpeg -v error -y -ss 8.2 -i web/assets/demo.mp4 -frames:v 1 -update 1 -q:v 3 web/assets/demo-poster.jpg
# Stills framed like the film: the band under the menu bar, a dark bezel strip
# above it and the notch tab (drawn at film scale, 1600/1800, so scaled back
# up for these source-scale crops), so the drop hangs from hardware here too.
ffmpeg -v error -y -i "$WORK/hero-full.png" -i "$WORK/notch.png" -filter_complex \
  "[1:v]scale=405:-1[tab];[0:v]crop=1800:406:612:48,pad=1800:446:0:40:color=black[b];[b][tab]overlay=697:0" \
  -frames:v 1 -update 1 docs/assets/palette.png
echo "✓ Assets written: web/assets/demo.mp4, demo-poster.jpg, docs/assets/palette.png"
echo "  Review them, then: git add web/assets docs/assets && git commit && git push"
