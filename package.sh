#!/bin/zsh
# Builds Szerverpanel and packages it into a drag-to-install disk image: build/Szerverpanel-<version>.dmg
set -euo pipefail
cd "${0:A:h}"

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Szerverpanel.app/Contents/Info.plist)
DMG="build/Szerverpanel-$VERSION.dmg"
STAGE=build/dmg

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto build/Szerverpanel.app "$STAGE/Szerverpanel.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Szerverpanel $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov -quiet "$DMG"
rm -rf "$STAGE"
echo "Packaged: $DMG"
