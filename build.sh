#!/bin/sh
# Wraps the SwiftPM binary in an .app so it runs as a menu bar agent (no Dock icon).
set -e
cd "$(dirname "$0")"
swift build -c release
app=build/GHToolbox.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/GHToolbox "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>GHToolbox</string>
  <key>CFBundleIdentifier</key><string>com.jimmy.ghtoolbox</string>
  <key>CFBundleName</key><string>GH Toolbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign -s - --force "$app"
echo "built $app"
