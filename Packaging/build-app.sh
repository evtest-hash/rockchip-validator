#!/bin/bash
# Assembles AZ0XValidator.app for macOS 13 and later, universal for arm64 and x86_64.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/AZ0XValidator.app"
CONTENTS="$APP/Contents"

# Resolved before anything expensive runs: an unversionable tree must fail in a second rather
# than after a universal build. The version is stamped into the bundle, never into the
# repository's Info.plist, which carries no version keys at all.
VERSION="${VALIDATOR_VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || true)}"
if [ -z "$VERSION" ]; then
    # Refusing to package is the point: a bundle whose version cannot be determined would
    # produce reports that name no build, and every report has to be traceable to one.
    echo "✗ cannot determine a version: git describe failed and VALIDATOR_VERSION is unset" >&2
    echo "  pass it explicitly, e.g. VALIDATOR_VERSION=0.2.0 $0" >&2
    exit 1
fi
VERSION="${VERSION#v}"
# CFBundleVersion carries the short commit hash, mapping an app back to a commit. It is omitted
# when there is no hash, since a placeholder there would claim a commit that does not exist.
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)"

echo "==> fetching bundled tools, versions pinned by Packaging/tools.lock, sha256 verified"
"$ROOT/Packaging/fetch-tools.sh"

echo "==> building universal, arm64 and x86_64, release"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT"

PRODUCTS="$ROOT/.build/apple/Products/Release"
BIN="$PRODUCTS/RockchipValidator"
[ -f "$BIN" ] || { echo "✗ product not found: $BIN"; exit 1; }

echo "==> assembling the bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers"

cp "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"

# Adding rather than setting: the template holds no version keys, so a Set would fail loudly
# if this block were ever skipped, instead of leaving a stale number behind.
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
    "$CONTENTS/Info.plist"
if [ -n "$COMMIT" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $COMMIT" "$CONTENTS/Info.plist"
fi
echo "    version: $VERSION (${COMMIT:--})"

# Application icon, referenced by CFBundleIconFile=AppIcon in Info.plist.
if [ ! -f "$ROOT/Packaging/AppIcon.icns" ]; then
    echo "    icns missing, generating from the master image"
    "$ROOT/Packaging/make-appicon.sh" | sed 's/^/    /'
fi
cp "$ROOT/Packaging/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$BIN" "$CONTENTS/MacOS/RockchipValidator"

# SPM resource bundles, which hold the board-side payloads fetched through Bundle.module.
shopt -s nullglob
bundles=("$PRODUCTS"/*.bundle)
if [ ${#bundles[@]} -eq 0 ]; then
    echo "✗ SPM resource bundle not found; the payloads would be unreachable"; exit 1
fi
for b in "${bundles[@]}"; do
    cp -R "$b" "$CONTENTS/Resources/"
    echo "    resource bundle: $(basename "$b")"
done

# External tools
missing=0
# The tool list is derived from tools.lock rather than duplicated.
TOOLS=($(grep -v '^[[:space:]]*\(#\|$\)' "$ROOT/Packaging/tools.lock" \
         | cut -d'|' -f5 | tr ' ' '\n' | sed 's|.*/||' | sort -u))
[ ${#TOOLS[@]} -gt 0 ] || { echo "✗ no tools parsed from tools.lock"; exit 1; }
for t in "${TOOLS[@]}"; do
    if [ -f "$ROOT/Vendor/bin/$t" ]; then
        cp "$ROOT/Vendor/bin/$t" "$CONTENTS/Helpers/$t"
        chmod +x "$CONTENTS/Helpers/$t"
    else
        echo "    ✗ missing Vendor/bin/$t"; missing=1
    fi
done
[ $missing -eq 0 ] || { echo "✗ external tools incomplete; the resulting app cannot work"; exit 1; }

# Tool version list for the report header. Resources, not Helpers: `Contents/Helpers` is a nested
# code location, and `codesign --verify --deep --strict` has no business sealing a text file as
# code. `BundledTools.readToolVersions` looks in Resources first for this reason.
cp "$ROOT/Vendor/bin/tools.version" "$CONTENTS/Resources/tools.version"

echo "==> ad-hoc signing; internal distribution, no Developer ID notarisation"
# Sign the bundled executables and dylibs first, then the bundle.
for t in "${TOOLS[@]}"; do
    codesign --force --sign - --timestamp=none "$CONTENTS/Helpers/$t"
done
codesign --force --sign - --timestamp=none "$CONTENTS/MacOS/RockchipValidator"
codesign --force --deep --sign - --timestamp=none "$APP"

echo "==> verifying"
echo "    architectures: $(lipo -archs "$CONTENTS/MacOS/RockchipValidator")"
echo "    size: $(du -sh "$APP" | cut -f1)"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Format" | sed 's/^/    /'
echo
echo "✅ $APP"
echo
echo "   First launch: unsigned internal build, so Gatekeeper blocks it once."
echo "   Right-click the app and choose Open, or allow it in System Settings > Privacy & Security."
