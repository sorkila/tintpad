cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.3.1"
  sha256 "10cdd92e85cea7e1a7c9cfd83746fac688ce15cdb4a5ee994438109fe62ead09"

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
