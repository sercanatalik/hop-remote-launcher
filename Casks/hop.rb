cask "hop" do
  version "1.5.0"
  sha256 "ccbca171aa99dcecb096887774875508796a679d9ca944bc09a1d19718ffa10b"

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
