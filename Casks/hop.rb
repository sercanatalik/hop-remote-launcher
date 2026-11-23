cask "hop" do
  version "1.4.0"
  sha256 "7fc6df6aa674da5bfc9bce6ed5b5be49a16b50f83cbea63ed375e752f4bce376"

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
