# Recording the demo

The demo records itself. `TINTPAD_DEMO=1` plays a scripted sequence on the
palette model (summon, arrow through tiles, type a filter, clear it, cycle
modes), driven from inside the app: no synthetic keystrokes, no Accessibility
grants, identical every take. The beat list lives in `TintpadApp.swift`.

| File | Used by |
|---|---|
| `web/assets/demo.mp4` | the video on tintpad.com |
| `web/assets/demo-poster.jpg` | that video's poster frame |
| `web/assets/og.png` | Open Graph / Twitter share card |
| `docs/assets/palette.png` | README hero |
| `docs/assets/demo.gif` | optional README animation, Product Hunt |

## The recipe

Run on a clean desktop (whatever is behind the glass ends up in the assets).

```sh
# 1. Learn the panel rect for this screen (written by the showcase harness).
pkill -x Tintpad; rm -f /tmp/tintpad-panel-rect
TINTPAD_SHOWCASE=1 .build/debug/Tintpad & sleep 3
RECT=$(cat /tmp/tintpad-panel-rect); pkill -x Tintpad

# 2. Record: start the recorder FIRST so the summon morph opens the clip.
screencapture -v -V 9 -R "$RECT" demo.mov & sleep 0.6
TINTPAD_DEMO=1 .build/debug/Tintpad
wait; pkill -x Tintpad

# 3. Convert + poster.
avconvert --source demo.mov --output web/assets/demo.mp4 --preset PresetHighestQuality
ffmpeg -y -ss 1.0 -i web/assets/demo.mp4 -frames:v 1 -q:v 3 web/assets/demo-poster.jpg
```

Stills: `TINTPAD_SHOWCASE=1` (summons at launch, survives focus loss, writes
the rect) plus a fullscreen `screencapture -x` and a 2x `sips` crop of the
rect. A direct `-R` capture comes out 1x on some setups, so crop from the
fullscreen for retina. The og card is the hero center-cropped to 1520×760,
then scaled to 1280×640.

## Taste notes

- The rect includes a 40pt pad so the pieces' shadows breathe.
- Terminal text behind the glass is on-brand; a personal browser is not.
- End the clip at rest, not mid-motion, so the loop point is calm.
- Use a release build for anything published, so marks render at full scale.
- Optional README gif: `ffmpeg -i demo.mp4 -vf "fps=12,scale=640:-1" demo.gif`,
  keep it under ~2MB (`gifsicle -O3 --lossy=80` if needed).

## After

```sh
git add docs/assets web/assets && git commit -m "docs: re-shoot demo assets" && git push
```

Pushing deploys `web/` to tintpad.com via `.github/workflows/deploy-web.yml`.
Check the share card afterwards, `og.png` is cached aggressively by the
social crawlers.
