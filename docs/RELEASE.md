# Tintpad, Releasing

One command cuts a release: `./Scripts/release.sh`. It checks the repo first, then
builds, signs, notarizes, signs the Sparkle update, publishes the GitHub release, and
rewrites the appcast, the Homebrew cask and the site's version stamp for you to
commit. Everything below is
what it needs and what it does.

## One-time setup

**1. Developer ID certificate** in the login keychain (`Developer ID Application: … (TEAMID)`).

**2. Notary profile**, with an app-specific password (not the Apple ID password):

```sh
xcrun notarytool store-credentials tintpad-notary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

**3. GitHub CLI**: `gh auth login`.

**4. The Sparkle key as a file**, so signing the update runs headless. The private
EdDSA key lives in the login keychain (generated once, shared with your other apps,
its public half is `SUPublicEDKey` in `Resources/Info.plist`). Reading it from the
keychain shows a GUI approval prompt, which hangs any headless or sandboxed shell.
Export it once to a file that only you can read:

```sh
mkdir -p ~/.config/sparkle && chmod 700 ~/.config/sparkle
(umask 077 && .build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/.config/sparkle/ed25519.key)
chmod 600 ~/.config/sparkle/ed25519.key
```

Run it from a real terminal after any `swift build` (which fetches Sparkle's tools),
pick a path that does not exist yet, and click Allow when macOS asks to let
`generate_keys` read "Private key for signing Sparkle updates". Keep the file
**outside this repo**: the repo lives on iCloud Drive, and everything under it syncs,
gitignored folders included. `release.sh` refuses a key file inside the repo unless
git ignores it, and warns when its mode is not 600.

Check that the file holds the key the app trusts, without printing it:

```sh
printf 'check' > /tmp/sparkle-check
SIG="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file ~/.config/sparkle/ed25519.key -p /tmp/sparkle-check)"
swift Scripts/verify-ed25519.swift \
  "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)" "$SIG" /tmp/sparkle-check \
  && echo "the key file matches SUPublicEDKey"
rm /tmp/sparkle-check
```

Then point the release at it, in `~/.zshrc` or per run:

```sh
export SPARKLE_ED_KEY_FILE="$HOME/.config/sparkle/ed25519.key"
```

Without `SPARKLE_ED_KEY_FILE`, `release.sh` still works the old way: `sign_update`
reads the keychain and macOS shows the approval prompt, so run it from a real
terminal and click Allow. The keychain stays the master copy either way. If the
file is ever lost, export it again.

Optional, only if the manual Release workflow should sign too:
`gh secret set SPARKLE_ED_KEY -R sorkila/tintpad < ~/.config/sparkle/ed25519.key`.

## Cutting a release

1. **Bump both versions** in `Resources/Info.plist`: `CFBundleShortVersionString`
   (what people read) and `CFBundleVersion` (an integer, the number Sparkle compares,
   it must go up every release).
2. **Name the CHANGELOG section.** Rename `## [Unreleased]` to
   `## [X.Y.Z] - YYYY-MM-DD`. That section becomes the "New in X.Y.Z" part of the
   GitHub release, so write it for someone deciding whether to update.
3. **Commit and push to main.** CI runs `check-release.sh --ci`, which fails if the
   version went up without the build number or without a CHANGELOG section.
4. **Preview**: `./Scripts/release.sh --dry-run`. It runs the preflight, renders the
   release notes, shows which key will sign, and stops. No credentials needed.
5. **Release**:

   ```sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE="tintpad-notary" \
   ./Scripts/release.sh
   ```

6. **Do the three steps it prints**: commit and push `web/appcast.xml`,
   `web/index.html`, `web/sitemap.xml` and `Casks/tintpad.rb` (the push deploys the
   appcast and the stamped site to tintpad.com, which is the moment
   installed copies see the update), copy the cask into `sorkila/homebrew-tap`, and
   test `brew install --cask sorkila/tap/tintpad`.

## What release.sh does, in order

1. **Preflight**, `Scripts/check-release.sh`. Info.plist carries the version, and both
   the version and the build number are above the newest item in the live appcast
   (`SUFeedURL`) and in `web/appcast.xml`. CHANGELOG.md has a dated, non-empty section
   for the version. The tree is clean, tag `vX.Y.Z` is unused locally and on origin, and
   HEAD is on origin. The cask has the two lines it will rewrite. Any failure stops the
   run before anything is built.
2. **Package**, `Scripts/package.sh`: release build, Developer ID signature with the
   hardened runtime (Sparkle signed inside-out first), DMG, notarization, staple.
3. **Sign the update** with `sign_update`, from `SPARKLE_ED_KEY_FILE` or the keychain,
   then verify the signature against `SUPublicEDKey` (`Scripts/verify-ed25519.swift`)
   and the signed length against the DMG. A DMG signed with the wrong key would be
   refused by every installed copy, so a mismatch stops the release here, before
   anything is public.
4. **Publish the GitHub release** with the DMG, the tag pinned to the commit the DMG
   was built from (`--target`), and notes rendered from `Scripts/release-notes.md`
   around the CHANGELOG section. Then read the release back and stop unless it is
   published (not a draft) and its `Tintpad.dmg` has the size and sha256 of the DMG
   that was signed, so the appcast never points at a 404 or a different file.
5. **Write `web/appcast.xml`** with the new item, its signature, length and date.
6. **Rewrite `Casks/tintpad.rb`** with the version and the DMG's sha256.
7. **Stamp the site**: the version line and the JSON-LD in `web/index.html`, the
   `lastmod` in `web/sitemap.xml`.

## When a release fails halfway

Before step 4 nothing is public: fix the cause and run `release.sh` again.

From step 4 on, the release exists on GitHub, published or left as a draft
(`gh release create` drafts, uploads, then publishes, and can fail in between). Fix
the cause and run `./Scripts/release.sh --republish`. Its preflight accepts what the
first run left behind: the tag at HEAD or not created yet, the version and build
already in the appcast if you committed it, and uncommitted changes to the files a
release writes (`web/appcast.xml`, `Casks/tintpad.rb`, `web/index.html`,
`web/sitemap.xml`). A tag at any other commit still stops it.

A republish **rebuilds and re-notarizes**, so the DMG, its Sparkle signature and its
sha256 all change. It replaces the DMG and notes on the release, publishes it if it
was a draft, and writes the appcast, cask and site stamp again. Commit and push those
files again even if the first run's versions were already committed: the old
signature and sha256 do not match the new DMG, so Sparkle and Homebrew would both
refuse it. Copy the cask into the tap again too.

## Release notes

`Scripts/release-notes.md` is the template: "New in X.Y.Z" with the CHANGELOG section
(its headings demoted a level, its hard-wrapped lines joined, since GitHub renders a
newline in a release body as a line break), the demo poster, how to install or update
with the DMG's sha256, a folded "What Tintpad is", and a link to the full CHANGELOG.
Edit the template for anything that should appear on every release. Anything about
one release belongs in its CHANGELOG section.

## Checks you can run any time

```sh
./Scripts/check-release.sh --ci   # what CI runs, passes on a resting main
./Scripts/check-release.sh        # the full release preflight
./Scripts/check-release.sh --republish   # the preflight release.sh --republish runs
./Scripts/test-release.sh         # self-test of the release scripts against fixtures
./Scripts/package.sh && ./Scripts/check-bundle.sh   # unsigned bundle, then its structure
```

Without `SIGN_IDENTITY`, `package.sh` produces a runnable unsigned DMG for local
testing.

## CI

`.github/workflows/ci.yml` runs on every push to main and every pull request, on
`macos-15` (the floor) and `macos-26` (the newer toolchain, allowed to fail). It
builds the app and the tests with warnings as errors, runs the tests, assembles the
unsigned bundle through `package.sh` with a release build, checks the bundle, runs
`check-release.sh --ci` and the release scripts' self-test. The GUI smoke test
(`Scripts/uitest.sh`) needs TCC grants a hosted runner cannot give, so it stays
local.

`.github/workflows/release.yml` is a manual build that uploads the app as a workflow
artifact. It signs and notarizes only when the signing secrets are set, and it
publishes nothing. `release.sh` is the release.

## Launch notes (from the original brief)

- Homebrew cask pointing at the notarized DMG (mirror the LockPaw cask).
- GitHub repo: `sorkila/tintpad` (referenced by the landing page + About).
- **Pre-launch:** LinkedIn build-in-public, `web/index.html` landing page live at
  tintpad.com with a direct download (no waitlist, it's free).
- **Launch day:** Product Hunt (00:01 PT), Show HN ("summon any coding agent into
  your terminal at the right repo in 2s"), r/macapps · r/ClaudeAI · r/ChatGPTCoding ·
  r/commandline · r/swift.
- **Sustain:** SEO blog posts (the GUI PATH problem, Safe vs YOLO, per-terminal
  setup guides), a complementary Raycast extension, the open-source GitHub-star halo.
- **Watch:** GitHub stars, launch-day downloads, which terminal adapters dominate,
  sponsors, review velocity.
