#!/bin/bash
# Generates AppIcon.icns from Packaging/AppIcon.png.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Packaging/AppIcon.png"
[ -f "$SRC" ] || { echo "✗ master image missing: $SRC"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"

# The ten sizes an .icns requires.
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec
    sips -Z "$1" "$SRC" --out "$SET/$2.png" >/dev/null
done

iconutil -c icns "$SET" -o "$ROOT/Packaging/AppIcon.icns"
ls -la "$ROOT/Packaging/AppIcon.icns" | awk '{print "    icns: " $5 " bytes"}'
