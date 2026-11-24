#!/bin/bash
# Builds Hop.app from Hop.swift.
#
# Usage:  ./build.sh             -> build/Hop.app (for this Mac's CPU)
#         ./build.sh --install   -> also copies it to /Applications and launches it
#
# Environment:
#   UNIVERSAL=1      build one app for both Apple silicon and Intel
#   VERSION=1.7.0    version shown in About (default: 1.6.0)
set -euo pipefail
cd "$(dirname "$0")"

command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }

APP="build/Hop.app"
VERSION="${VERSION:-1.6.0}"
MIN_OS="13.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() { # $1 = arch, $2 = output
  echo "Compiling for $1…"
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$1-apple-macos$MIN_OS" \
    Hop.swift -o "$2"
}

if [[ "${UNIVERSAL:-}" == "1" ]]; then
  compile arm64  "build/Hop-arm64"
  compile x86_64 "build/Hop-x86_64"
  lipo -create build/Hop-arm64 build/Hop-x86_64 -output "$APP/Contents/MacOS/Hop"
  rm -f build/Hop-arm64 build/Hop-x86_64
else
  compile "$(uname -m)" "$APP/Contents/MacOS/Hop"
fi

cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hop</string>
  <key>CFBundleDisplayName</key><string>Hop</string>
  <key>CFBundleIdentifier</key><string>io.github.sercanatalik.hop</string>
  <key>CFBundleExecutable</key><string>Hop</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licence · github.com/sercanatalik/hop-remote-launcher</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Hop finds computers on your network, checks whether they are online and can wake them.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_rfb._tcp</string>
    <string>_ssh._tcp</string>
    <string>_smb._tcp</string>
    <string>_device-info._tcp</string>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built: $APP ($VERSION)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Hop 2>/dev/null || true
  pkill -x MacLauncher 2>/dev/null || true
  rm -rf "/Applications/Hop.app"
  cp -R "$APP" /Applications/
  open "/Applications/Hop.app"
  echo "Installed to /Applications and launched — look for the Hop icon in the menu bar."
  if [[ -d "/Applications/Mac Launcher.app" ]]; then
    echo "Note: the old 'Mac Launcher.app' is still in /Applications — drag it to the Bin when you're happy with Hop."
  fi
fi
