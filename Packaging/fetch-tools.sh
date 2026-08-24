#!/bin/bash
# Fetches the bundled tools into Vendor/bin according to Packaging/tools.lock.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/Packaging/tools.lock"
CACHE="$ROOT/Vendor/cache"
BIN="$ROOT/Vendor/bin"

[ -f "$LOCK" ] || { echo "✗ cannot find $LOCK"; exit 1; }
mkdir -p "$CACHE" "$BIN"

# This script runs on the bash 3.2 shipped with macOS, which is not multi-byte aware.
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

versions=()

# One temporary directory for the whole run, with the trap installed once.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The manifest is read on fd 3: curl and tar inside the loop consume stdin, which would eat it.
while IFS='|' read -r -u 3 id version url sha members; do
    case "${id:-}" in ''|\#*) continue ;; esac

    case "$url" in
        *.tar.gz) ext="tar.gz" ;;
        *.zip)    ext="zip" ;;
        *) echo "✗ ${id}: unrecognised archive type $url"; exit 1 ;;
    esac
    archive="$CACHE/$id-$version.$ext"

    if [ -f "$archive" ] && [ "$(sha_of "$archive")" = "$sha" ]; then
        echo "    cache hit: $id $version"
    else
        echo "==> downloading $id $version"
        curl -fL --retry 3 --progress-bar -o "$archive.part" "$url"
        got="$(sha_of "$archive.part")"
        if [ "$got" != "$sha" ]; then
            rm -f "$archive.part"
            echo "✗ $id sha256 mismatch; aborted"
            echo "  expected $sha"
            echo "  actual   $got"
            exit 1
        fi
        mv "$archive.part" "$archive"
    fi

    # Skip extraction when every member is present and no older than the archive.
    fresh=1
    for m in $members; do
        f="$BIN/$(basename "$m")"
        { [ -f "$f" ] && [ ! "$archive" -nt "$f" ]; } || { fresh=0; break; }
    done

    if [ $fresh -eq 1 ]; then
        echo "    ready: $id $version"
    else
        work="$tmp/$id"; rm -rf "$work"; mkdir -p "$work"
        # Extract only the members that are used, not the whole archive.
        case "$ext" in
            tar.gz) tar xzf "$archive" -C "$work" $members ;;
            zip)    unzip -o -q -j "$archive" $members -d "$work" ;;
        esac
        for m in $members; do
            # zip is extracted with -j, which discards paths, while tar keeps them.
            src="$work/$m"; [ -f "$src" ] || src="$work/$(basename "$m")"
            [ -f "$src" ] || { echo "✗ $m is not in the $id archive"; exit 1; }
            cp "$src" "$BIN/$(basename "$m")"
            chmod +x "$BIN/$(basename "$m")"
        done
    fi

    versions+=("$id $version")
done 3< "$LOCK"

# The tool versions are written to disk because the report prints them.
[ ${#versions[@]} -gt 0 ] || { echo "✗ no valid records in ${LOCK}"; exit 1; }
printf '%s\n' "${versions[@]}" > "$BIN/tools.version"

echo "==> tools ready in ${BIN}"
sed 's/^/    /' "$BIN/tools.version"
