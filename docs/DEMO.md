# Recording the demo

> **These assets are currently out of date.** Every one of them was shot before the
> palette was rebuilt as a terminal HUD, so the README, tintpad.com, and every social
> share card presently advertise a UI that no longer exists. Re-shooting them is the
> open task.

What needs to be regenerated, all of it showing the same run:

| File | Used by |
|---|---|
| `docs/assets/demo.gif` | README hero, Product Hunt gallery |
| `web/assets/demo.mp4` | the video on tintpad.com |
| `web/assets/demo-poster.jpg` | that video's poster frame |
| `web/assets/og.png` | Open Graph / Twitter share card |

Target: a tight ~6-second loop that shows the one thing words can't.

## What to show (the script)
1. A clean desktop, no palette open.
2. Press the hotkey → palette springs in.
3. Type a couple letters → list filters by frecency.
4. `↓` to a repo, then `⌃W` (or just `↵`) → your terminal opens at that repo with
   the agent already running.

Lead with the **worktree** or the **handoff**, not a plain `↵`, show what an alias
can't. End the moment the terminal lands (don't film the agent working).

## Posing the palette

For stills (`og.png`, the poster frame) you don't want to fight the hotkey and the
auto-hide-on-focus-loss. There's a harness for it:

```sh
swift build
TINTPAD_SHOWCASE=1 ./.build/debug/Tintpad
```

That summons the palette at launch and keeps it up when it loses focus, so you can
capture it from a shell. It also writes the panel's frame to `/tmp/tintpad-panel-rect`
in `screencapture` coordinates, so you can crop to exactly the panel plus its shadow:

```sh
screencapture -x -o -R"$(cat /tmp/tintpad-panel-rect)" out.png
```

The flag is read only from the environment and never fires in a normal launch. Use a
release build for anything published, so the marks render at the right scale.

## How (you already have CleanShot)
- CleanShot X → **Record screen → GIF**. Frame a region ~1280×800 around the palette
  + the terminal. 15–20 fps is plenty.
- Keep it under ~6 s and loop-friendly (start and end on a similar frame).
- Export, then compress to keep it README-sane (aim < ~3 MB):
  - `gifsicle -O3 --lossy=80 --colors 200 in.gif -o docs/assets/demo.gif`
  - (or drop it into Gifski / ezgif.com if you don't have gifsicle)
- Tip: set the palette to a clean repo list first, and use a real agent so the
  terminal visibly starts it.
- Worth showing now that it exists: the numbered rows are <kbd>⌘1</kbd>–<kbd>⌘9</kbd>,
  so a jump-and-launch reads well on camera and explains the numbers without words.

## After
```sh
git add docs/assets/demo.gif web/assets/ && git commit -m "docs: re-shoot demo assets" && git push
```
Pushing also deploys the `web/` assets to tintpad.com via
`.github/workflows/deploy-web.yml`. Check the share card afterwards, `og.png` is the
one people see before they ever reach the site.
