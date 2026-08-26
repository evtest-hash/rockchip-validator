#!/bin/bash
# Packages dist/AZ0XValidator.app into a DMG for distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/AZ0XValidator.app"
[ -d "$APP" ] || { echo "✗ run Packaging/build-app.sh first"; exit 1; }

# The version is read from the app itself, which build-app.sh has already stamped.
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/AZ0XValidator-$VER.dmg"
VOL="AZ0X 物料验证 $VER"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# Conventional drag-install layout: a symlink to /Applications next to the app.
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
echo "==> packaging $VOL"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" \
               -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"

echo "==> verifying"
hdiutil verify -quiet "$DMG" && echo "    image intact"
echo "    size: $(du -h "$DMG" | cut -f1)"
echo "    sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "✅ $DMG"
