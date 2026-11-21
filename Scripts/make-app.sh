#!/bin/bash
# Builds "Disk Inventory X.app" from the Swift package (macOS only).
#
#   Scripts/make-app.sh            -> ./build/Disk Inventory X.app
#
# (You can also open Package.swift in Xcode and run the DiskInventoryX scheme.)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Disk Inventory X.app"
VERSION="${VERSION:-2.0}"

swift build -c release --product DiskInventoryX
BIN="$(swift build -c release --product DiskInventoryX --show-bin-path)/DiskInventoryX"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskInventoryX"

# icon: Resources/AppIcon.png -> AppIcon.icns
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp Resources/AppIcon.png       "$ICONSET/icon_512x512@2x.png"
rm "$ICONSET/icon_64x64.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Disk Inventory X</string>
    <key>CFBundleDisplayName</key>        <string>Disk Inventory X</string>
    <key>CFBundleIdentifier</key>         <string>org.example.DiskInventoryX</string>
    <key>CFBundleExecutable</key>         <string>DiskInventoryX</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>            <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built: $APP"
echo "Tip: to see every folder, give the app Full Disk Access in System Settings > Privacy & Security."
