cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.2.0"
  sha256 "2f7cb38ecd90d1287b41d6c91a8baa803a773f2d48caa05dc94c9aecfa3d44e4"

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
