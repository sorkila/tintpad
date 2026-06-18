cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

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
