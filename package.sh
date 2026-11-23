#!/bin/zsh
# Builds Lampion and packages it into a drag-to-install disk image: build/Lampion-<version>.dmg
set -euo pipefail
cd "${0:A:h}"

./build.sh --no-install
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Lampion.app/Contents/Info.plist)
DMG="build/Lampion-$VERSION.dmg"
STAGE=build/dmg

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto build/Lampion.app "$STAGE/Lampion.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Lampion $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov -quiet "$DMG"
rm -rf "$STAGE"
echo "Packaged: $DMG"
