#!/bin/zsh
# Assembles build/Vane.app from the SwiftPM executable and ad-hoc signs it.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}

swift build -c "$CONFIG" --product Aegis
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

APP=build/Vane.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Aegis" "$APP/Contents/MacOS/Aegis"
# SwiftPM resource bundles (WebEngine js, ContentBlocking lists, …)
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Development builds get their own identity (bundle ID, data folder, WebKit
# stores, Keychain items) so they can run beside the installed app safely.
# scripts/install.sh builds with AEGIS_RELEASE=1 for the real identity.
if [ "${AEGIS_RELEASE:-0}" != "1" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.aegis.browser.dev" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Vane Dev" "$APP/Contents/Info.plist"
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - --entitlements Resources/Aegis.entitlements --options runtime "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
