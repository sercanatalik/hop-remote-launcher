cask "hop" do
  version "1.1.1"
  sha256 "2784d1f4fedaedb8834bd6595b3450376788c81851994a1b12f4ac501cd159af"

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
