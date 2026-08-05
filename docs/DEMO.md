# Recording the demo

One command records and cuts everything:

```sh
./Scripts/record-demo.sh
```

Run it on an unlocked Mac (a locked screen records the lock screen — check the
output isn't black) with the current build installed (`./Scripts/dev-install.sh`)
and ffmpeg on PATH. It backs up your real store, seeds the portfolio repo names,
plays the scripted `TINTPAD_DEMO` beat list (in `TintpadApp.swift`), records the
raw take, then cuts every published asset and restores your store.

| Output | Used by |
|---|---|
| `web/assets/demo.mp4` | the film on tintpad.com (12s, 60fps) |
| `web/assets/demo-poster.jpg` | the video's poster frame (the red MODE dwell) |
| `web/assets/og.png` | Open Graph / Twitter share card |
| `docs/assets/palette.png` | README hero |

## How the film works

The cut is one continuous camera: four held framings (wide for the fall, medium
for the token walk, tight for the agent flip and red dwell, wide for the rest)
connected by fast quintic-eased dollies, each timed so an on-screen action masks
the camera move. The source is 3x oversampled before `zoompan` so slow moves stay
sub-pixel. The band crops below the menu bar; a rendered notch tab (signed-
distance PNG, generated inside the script) sits bezel-fixed at the top of frame.

Hard-won ffmpeg notes, so nobody relearns them:

- `fade=in:st=N` holds alpha at zero for ALL t < N. Chaining `fade=out,fade=in`
  on one stream blanks it — split into two streams and overlay both.
- `boxblur` derives a chroma radius that overflows short strips — set
  `luma_radius`/`chroma_radius` explicitly if you ever blur again.
- Raw takes survive in `$TMPDIR` (`tmp.*/demo-raw.mov`) — grading tweaks are a
  re-cut, not a re-record. The take is the negative, this script is the darkroom.

## Taste notes

- End the clip at rest, the loop point must be calm.
- The demo store pins `tintedChips` off — the film stays monochrome.
- Desktop copies for posting: `~/Desktop/tintpad-demo.mp4` (native wide),
  `tintpad-demo-16x9.mp4` (letterboxed for platforms that crop),
  `tintpad-demo.gif` (0.6MB, for comments).

## After

```sh
git add docs/assets web/assets && git commit -m "assets: re-shoot the film" && git push
```

Pushing deploys `web/` to tintpad.com. The og card is cached hard by social
crawlers — recheck with a card validator after changes.
