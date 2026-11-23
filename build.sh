#!/bin/zsh
# Szerverpanel.app építése és telepítése az /Applications mappába.
set -euo pipefail
cd "${0:A:h}"

APP=build/Szerverpanel.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Szerverpanel" Sources/**/*.swift

swift Tools/make-icon.swift build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" build/AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Szerverpanel</string>
  <key>CFBundleDisplayName</key><string>Szerverpanel</string>
  <key>CFBundleIdentifier</key><string>hu.local.szerverpanel</string>
  <key>CFBundleExecutable</key><string>Szerverpanel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
# Pass --no-install to only build into build/ (used for testing next to a running copy).
if [[ "${1:-}" == "--no-install" ]]; then
  echo "Built: $APP"
else
  ditto "$APP" /Applications/Szerverpanel.app
  echo "Installed: /Applications/Szerverpanel.app"
fi
