#!/bin/zsh
# Builds the release app (real identity) and packages it as build/Vane-<version>.dmg:
# Vane.app beside an Applications shortcut, compressed, ready to drag-install.
# Usage: scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VANE_RELEASE=1 scripts/bundle.sh release
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Vane.app/Contents/Info.plist)
DMG=build/Vane-$VERSION.dmg
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/Vane.app "$STAGE/Vane.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Vane $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --sign - "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
