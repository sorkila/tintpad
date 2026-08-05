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
  pkill -f demo-backdrop.swift 2>/dev/null || true
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
names = [("Velm", claude, 9.0, True), ("Kuta", claude, 7.5, False),
         ("Lockpaw", codex, 6.2, False), ("Dela", claude, 5.1, False),
         ("Tintpad", claude, 4.0, False), ("shipit", codex, 3.1, False),
         ("regretbox", claude, 2.2, False), ("unnamed-3", claude, 1.4, False)]
s['repos'] = [{
    "addedVia": "manual", "frecencyScore": score,
    "id": str(uuid.uuid4()).upper(), "lastAgentID": agent,
    "launchCount": int(score), "name": name,
    "path": f"/Users/eriknielsen/Repositories/{name}", "pinned": pinned,
} for name, agent, score, pinned in names]
s['sessions'] = []
with open(path, 'w') as f: json.dump(s, f, indent=1)
EOF

echo "▸ Staging backdrop…"
cat > "$WORK/demo-backdrop.swift" <<'EOF'
import AppKit
final class V: NSView { override func draw(_ r: NSRect) {
    NSGradient(colors: [NSColor(calibratedWhite: 0.075, alpha: 1),
                        NSColor(calibratedWhite: 0.03, alpha: 1)])?
        .draw(fromCenter: NSPoint(x: bounds.midX, y: bounds.height * 0.72), radius: 0,
              toCenter: NSPoint(x: bounds.midX, y: bounds.height * 0.72),
              radius: max(bounds.width, bounds.height) * 0.9, options: [])
} }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let s = NSScreen.screens.first else { exit(1) }
let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
w.backgroundColor = .black; w.contentView = V(); w.orderFrontRegardless()
app.run()
EOF
swift "$WORK/demo-backdrop.swift" & sleep 5

echo "▸ Recording (10s)…"
screencapture -v -V 10 "$WORK/demo-raw.mov" & sleep 0.7
TINTPAD_DEMO=1 TINTPAD_SCREEN_PRIMARY=1 "$APP" & sleep 11.5
pkill -x Tintpad || true

echo "▸ Hero still…"
TINTPAD_SHOWCASE=1 TINTPAD_SCREEN_PRIMARY=1 "$APP" & sleep 3.5
screencapture -x "$WORK/hero-full.png"
pkill -x Tintpad || true
pkill -f demo-backdrop.swift || true

echo "▸ Cutting assets…"
# Screen is 3024x1964 (2x). The band: menu bar + notch + drop, centered.
ffmpeg -y -i "$WORK/demo-raw.mov" -vf "crop=2000:440:512:0,fps=30" \
  -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart -an \
  web/assets/demo.mp4
ffmpeg -y -ss 2.6 -i web/assets/demo.mp4 -frames:v 1 -q:v 3 web/assets/demo-poster.jpg
sips -c 440 2000 --cropOffset 0 512 "$WORK/hero-full.png" --out docs/assets/palette.png >/dev/null
sips -c 800 1600 --cropOffset 0 712 "$WORK/hero-full.png" --out "$WORK/og-crop.png" >/dev/null
sips -z 640 1280 "$WORK/og-crop.png" --out web/assets/og.png >/dev/null

echo "✓ Assets written: web/assets/demo.mp4, demo-poster.jpg, og.png, docs/assets/palette.png"
echo "  Review them, then: git add web/assets docs/assets && git commit && git push"
