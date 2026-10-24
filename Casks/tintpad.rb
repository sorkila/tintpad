cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.4.2"
  sha256 "60eff31d8f6d3ae2f0a6a047d70cbc4712bda09e88952b2c115ad9e05aaf5b46"

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
