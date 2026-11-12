#!/bin/zsh
# Builds the release app (real identity) and packages it as build/Aegis-<version>.dmg:
# Aegis.app beside an Applications shortcut, compressed, ready to drag-install.
# Usage: scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
AEGIS_RELEASE=1 scripts/bundle.sh release
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Aegis.app/Contents/Info.plist)
DMG=build/Aegis-$VERSION.dmg
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/Aegis.app "$STAGE/Aegis.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Aegis $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --sign - "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
