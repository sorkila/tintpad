cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.4.3"
  sha256 "9c6dd7708d9bf3da2eaf8d772b1a188fd4bfb4492373e487ee9528597fb9ab1f"

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
