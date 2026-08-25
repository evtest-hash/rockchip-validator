#!/bin/bash
# Assembles a runnable .app around the built binary.
#
# Layout matches what `BundledTools` looks for: the three CLIs live in Contents/Helpers, which is a
# sibling of Contents/MacOS, and the core's resource bundle goes to Contents/Resources so that the
# board-side payloads are found through `Bundle.module`.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="dist/AZ0XValidator.app"

swift build -c "$CONFIG" --product AZ0XValidator
BIN=".build/$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN/AZ0XValidator" "$APP/Contents/MacOS/AZ0XValidator"
cp Vendor/bin/* "$APP/Contents/Helpers/"
# SwiftPM names the resource bundle after the package and target.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AZ0X 物料验证台</string>
  <key>CFBundleDisplayName</key><string>AZ0X 物料验证台</string>
  <key>CFBundleExecutable</key><string>AZ0XValidator</string>
  <key>CFBundleIdentifier</key><string>com.focalcrest.az0x.validator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The window is the whole application; there is nothing to do without it. -->
  <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

echo "→ $APP"
