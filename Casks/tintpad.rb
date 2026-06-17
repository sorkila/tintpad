cask "tintpad" do
  # TODO: bump to the real release tag after a notarized build ships.
  version "0.0.0"

  # TODO: replace with the real DMG sha256. Get it with:
  #   shasum -a 256 .build/release/Tintpad.dmg
  # Then delete the `:no_check` line below and uncomment the literal.
  sha256 :no_check
  # sha256 "REPLACE_WITH_DMG_SHA256"

  # TODO: confirm the release asset name matches the DMG produced by
  # ./Scripts/package.sh (defaults to Tintpad.dmg).
  url "https://github.com/sorkila/tintpad/releases/download/v#{version}/Tintpad.dmg",
      verified: "github.com/sorkila/tintpad/"

  name "Tintpad"
  desc "Menu-bar launcher that summons a coding agent into your terminal at the right repo"
  homepage "https://tintpad.com"

  app "Tintpad.app"

  zap trash: [
    "~/Library/Application Support/Tintpad",
  ]
end
