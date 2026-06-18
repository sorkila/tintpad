# Recording the demo GIF

The README and PH gallery point at `docs/assets/demo.gif`. Drop the file there and
it just works — everything's already wired. Target: a tight ~6-second loop that
shows the one thing words can't.

## What to show (the script)
1. A clean desktop, no palette open.
2. Press the hotkey → palette springs in.
3. Type a couple letters → list filters by frecency.
4. `↓` to a repo, then `⌃W` (or just `↵`) → your terminal opens at that repo with
   the agent already running.

Lead with the **worktree** or the **handoff**, not a plain `↵` — show what an alias
can't. End the moment the terminal lands (don't film the agent working).

## How (you already have CleanShot)
- CleanShot X → **Record screen → GIF**. Frame a region ~1280×800 around the palette
  + the terminal. 15–20 fps is plenty.
- Keep it under ~6 s and loop-friendly (start and end on a similar frame).
- Export, then compress to keep it README-sane (aim < ~3 MB):
  - `gifsicle -O3 --lossy=80 --colors 200 in.gif -o docs/assets/demo.gif`
  - (or drop it into Gifski / ezgif.com if you don't have gifsicle)
- Tip: set the palette to a clean repo list first, and use a real agent so the
  terminal visibly starts it.

## After
```sh
git add docs/assets/demo.gif && git commit -m "docs: add demo gif" && git push
```
Pushing also deploys it to the site (it lives under web/ assets if you reference it
there too). Closes issue #8.
