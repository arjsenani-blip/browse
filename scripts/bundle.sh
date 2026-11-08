#!/bin/zsh
# Assembles build/Aegis.app from the SwiftPM executable and ad-hoc signs it.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}

swift build -c "$CONFIG" --product Aegis
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

APP=build/Aegis.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Aegis" "$APP/Contents/MacOS/Aegis"
# SwiftPM resource bundles (WebEngine js, ContentBlocking lists, …)
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - --entitlements Resources/Aegis.entitlements --options runtime "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
