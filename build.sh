#!/bin/sh
# Wraps the SwiftPM binary in an .app so it runs as a menu bar agent (no Dock icon).
set -e
cd "$(dirname "$0")"
swift build -c release
app="build/GitHub Toolbox.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/GHToolbox "$app/Contents/MacOS/"
iconset=build/AppIcon.iconset
rm -rf "$iconset" && mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size Icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>GHToolbox</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.jimmy.ghtoolbox</string>
  <key>CFBundleName</key><string>GitHub Toolbox</string>
  <key>CFBundleDisplayName</key><string>GitHub Toolbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign -s - --force "$app"
rm -rf "/Applications/GitHub Toolbox.app"
cp -R "$app" /Applications/
echo "installed /Applications/GitHub Toolbox.app"
