#!/bin/bash
# Packs "build/Disk Inventory X.app" (see make-app.sh) into a disk image (macOS only).
#
#   Scripts/make-dmg.sh            -> ./build/Disk-Inventory-X.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Disk Inventory X.app"
DMG="build/Disk-Inventory-X.dmg"
[ -d "$APP" ] || { echo "Run Scripts/make-app.sh first." >&2; exit 1; }

# the image shows the app next to a shortcut to /Applications (drag & drop install)
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Disk Inventory X" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

echo "Built: $DMG"
