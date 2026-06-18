cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.1.0"
  sha256 "ad15f11cc7aae878389fe5fba41396716e7a26008d68894c77f675ce85f0ccb4"

  url "https://github.com/sorkila/tintpad/releases/download/v#{version}/Tintpad.dmg",
      verified: "github.com/sorkila/tintpad/"

  name "Tintpad"
  desc "Menu-bar launcher that summons a coding agent into your terminal at the right repo"
  homepage "https://tintpad.com"

  depends_on macos: ">= :sonoma"

  app "Tintpad.app"

  zap trash: [
    "~/Library/Application Support/Tintpad",
    "~/Library/Caches/com.sorkila.tintpad",
    "~/Library/Preferences/com.sorkila.tintpad.plist",
  ]
end
