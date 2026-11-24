#!/bin/bash
# Runs Hop's checks: compiles Hop.swift, without its entry point, together with Tests/checks.swift.
#
# Usage:  ./test.sh            -> the checks that need nothing else
#         ./test.sh --live     -> also the ones that need a network on this computer
set -euo pipefail
cd "$(dirname "$0")"

command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }

OUT="build/checks"
rm -rf "$OUT"
mkdir -p "$OUT"
# The app's entry point would clash with the checks' own, so the copy goes without it.
grep -v '^@main$' Hop.swift > "$OUT/Hop.swift"
cp Tests/checks.swift "$OUT/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" "$OUT/Hop.swift" "$OUT/main.swift" -o "$OUT/checks"
"$OUT/checks" "$@"
