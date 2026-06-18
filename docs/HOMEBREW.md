# Tintpad, Homebrew

Ship Tintpad as a Homebrew cask. One command to install, one command to update.
The cask points at a notarized DMG attached to a GitHub release. Nothing fancy.

```sh
brew install --cask sorkila/tap/tintpad
```

The cask template lives at `Casks/tintpad.rb` in this repo. It carries TODO
markers for the two values only a real release can fill: `version` and `sha256`.

## Prerequisites

You need a **notarized, stapled DMG** first. The Homebrew cask is just a pointer.
See `docs/RELEASE.md`, short version:

```sh
SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
NOTARY_PROFILE="<notarytool profile>" \
  ./Scripts/package.sh
# → .build/release/Tintpad.dmg  (signed, hardened, notarized, stapled)
```

Gatekeeper must pass on a clean machine before you publish. Verify:

```sh
spctl -a -t open --context context:primary-signature -vvv .build/release/Tintpad.dmg
```

## 1. Cut the GitHub release

1. Tag and push: `git tag v0.1.0 && git push --tags`.
2. Create the release on `github.com/sorkila/tintpad` for tag `v0.1.0`.
3. Attach `Tintpad.dmg` as a release asset. Keep the asset name `Tintpad.dmg`
   so the cask's `url` resolves without edits.

## 2. Create the tap repo (once)

A tap is just a GitHub repo named `homebrew-<tap>`. For `sorkila/tap`:

1. Create `github.com/sorkila/homebrew-tap` (public, empty).
2. Add a `Casks/` directory.
3. Copy `Casks/tintpad.rb` from this repo into the tap's `Casks/`.

```sh
gh repo create sorkila/homebrew-tap --public --description "Homebrew tap for Sorkila apps"
git clone https://github.com/sorkila/homebrew-tap
mkdir -p homebrew-tap/Casks
cp Casks/tintpad.rb homebrew-tap/Casks/
```

The canonical source of truth is `Casks/tintpad.rb` in the Tintpad repo. The tap
gets a copy. Keep them in sync (the release step below does this).

## 3. Fill version + sha256

After the DMG is built and uploaded, compute the checksum and edit the cask:

```sh
shasum -a 256 .build/release/Tintpad.dmg
```

In `Casks/tintpad.rb`:

- Set `version` to the release tag without the `v` (e.g. `0.1.0`).
- Replace the `sha256 :no_check` line with `sha256 "<digest from above>"`.

The `:no_check` placeholder exists so the cask is syntactically valid before a
real release. Never ship `:no_check` to the tap, it disables integrity
verification. Fill the real digest first.

## 4. Publish to the tap

```sh
cp Casks/tintpad.rb homebrew-tap/Casks/tintpad.rb
cd homebrew-tap
git add Casks/tintpad.rb
git commit -m "tintpad 0.1.0"
git push
```

## 5. Verify the cask

Audit and a real install on a clean account:

```sh
brew tap sorkila/tap
brew audit --cask --online --strict sorkila/tap/tintpad
brew style sorkila/tap/tintpad
brew install --cask sorkila/tap/tintpad
brew uninstall --cask --zap tintpad   # confirms the zap stanza is clean
```

`--zap` should remove `~/Library/Application Support/Tintpad`. Tintpad is
local-only, no accounts, no telemetry, so that one directory is the whole
footprint.

## Updating later

Every release: bump `version`, recompute `sha256`, copy the cask to the tap,
commit, push. Users get it with `brew upgrade --cask tintpad`.

Note: Tintpad also ships Sparkle for in-app auto-update (see `docs/RELEASE.md`).
Sparkle and Homebrew are independent update paths. Brew users update via
`brew upgrade`, the cask doesn't need to know about the appcast.

---

## TODO before first publish

- [ ] Notarized, stapled `Tintpad.dmg` from `./Scripts/package.sh`.
- [ ] GitHub release `v0.1.0` with `Tintpad.dmg` attached.
- [ ] `version` set to `0.1.0` in `Casks/tintpad.rb`.
- [ ] `sha256` filled with the real digest (no `:no_check`).
- [ ] `github.com/sorkila/homebrew-tap` created with the cask copied in.
- [ ] `brew audit --cask --online --strict` passes.
