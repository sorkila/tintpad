cask "tintpad" do
  # version + sha256 are filled automatically by Scripts/release.sh.
  version "0.3.2"
  sha256 "b8eb9ceb75a4e3c9c7837bce425e77b5dc2b9e2738077fc5cbe24a569d4562db"

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
