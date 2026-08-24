cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.3.6"
  sha256 "d2baea3c70a37986dde57d72fa4402f114b02ae73b61637c3dc7610fb9eb6085"

  url "https://github.com/sorkila/tintpad/releases/download/v#{version}/Tintpad.dmg",
      verified: "github.com/sorkila/tintpad/"

  name "Tintpad"
  desc "Menu-bar launcher that summons a coding agent into your terminal at the right repo"
  homepage "https://tintpad.com"

  depends_on macos: :sonoma

  app "Tintpad.app"

  zap trash: [
    "~/Library/Application Support/Tintpad",
    "~/Library/Caches/com.sorkila.tintpad",
    "~/Library/Preferences/com.sorkila.tintpad.plist",
  ]
end
