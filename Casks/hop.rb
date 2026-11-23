cask "hop" do
  version "1.3.0"
  sha256 "d04ade926760bd0e5b0878d449529d16081fb3d1ca22bd356b2eb5bd827d4baa"

  url "https://github.com/sercanatalik/hop-remote-launcher/releases/download/v#{version}/Hop.zip",
      verified: "github.com/sercanatalik/hop-remote-launcher/"
  name "Hop"
  desc "Menu-bar launcher for remote Macs, Tailscale, SSH, and Screen Sharing"
  homepage "https://sercanatalik.github.io/hop-remote-launcher/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "Hop.app"

  zap trash: [
    "~/Library/Application Support/Hop",
    "~/Library/Preferences/io.github.sercanatalik.hop.plist",
  ]
end
