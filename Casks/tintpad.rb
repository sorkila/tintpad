cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.4.1"
  sha256 "db640aad741a3b585a0ac7a2dd22a396e36c7f2efbbb262590dc9f6c17ec4579"

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
