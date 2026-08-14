cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.3.3"
  sha256 "150a38a0c0effbace63072b82bccfa76b8c39efcc9c8fef02eaf37d835e31e35"

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
