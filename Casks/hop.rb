cask "hop" do
  version "1.2.0"
  sha256 "053a4709d7867d2a216b02a019a214c6c9985edfb7dec6e39a8a6178584833cc"

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
