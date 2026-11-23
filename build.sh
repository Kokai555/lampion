#!/bin/zsh
# Lampion.app építése és telepítése az /Applications mappába.
set -euo pipefail
cd "${0:A:h}"

APP=build/Lampion.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Lampion" Sources/**/*.swift

swift Tools/make-icon.swift build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" build/AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lampion</string>
  <key>CFBundleDisplayName</key><string>Lampion</string>
  <key>CFBundleIdentifier</key><string>hu.local.lampion</string>
  <key>CFBundleExecutable</key><string>Lampion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

# Synced folders (iCloud Drive etc.) attach Finder/file-provider attributes that codesign rejects.
xattr -cr "$APP"
codesign --force --sign - "$APP"
# Pass --no-install to only build into build/ (used for testing next to a running copy).
if [[ "${1:-}" == "--no-install" ]]; then
  echo "Built: $APP"
else
  ditto "$APP" /Applications/Lampion.app
  echo "Installed: /Applications/Lampion.app"
fi
