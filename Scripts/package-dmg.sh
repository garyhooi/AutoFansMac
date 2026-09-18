#!/usr/bin/env bash
#
# Scripts/package-dmg.sh — build a distributable DMG around a signed app.
#
# Usage:  Scripts/package-dmg.sh [path/to/AutoFansMac.app] [output.dmg]
#
# The layout is a plain drag-to-Applications window: the app on the left, an
# /Applications symlink on the right. Nothing else, because the app needs to end up in
# /Applications: its LaunchDaemon plist points at the canonical absolute path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_PATH="${1:-$REPO_ROOT/build/AutoFansMac.xcarchive/Products/Applications/AutoFansMac.app}"
OUTPUT_DMG="${2:-$REPO_ROOT/build/AutoFansMac-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 1.0).dmg}"

if [ ! -d "$APP_PATH" ]; then
    echo "No app at $APP_PATH" >&2
    echo "Build one first: Scripts/build.sh   (or pass a path)" >&2
    exit 1
fi

echo "==> Checking the app signature"
codesign --verify --strict "$APP_PATH"

# The daemon is copied out of the bundle at install time, so it must not load anything
# from outside the system (see Packages/SMCKit/Package.swift for why the product is static).
# `otool -L` prints a "path (architecture):" header per slice for fat binaries.
non_system_deps() {
    otool -L "$1" \
        | grep -v ':$' | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//; s/ (compatibility.*$//; s/ (architecture.*$//' \
        | grep -vE '^(/usr/lib|/System/Library)' || true
}

HELPER_BIN="$APP_PATH/Contents/Library/LaunchDaemons/AutoFansMacHelper"
UNEXPECTED="$(non_system_deps "$HELPER_BIN")"
if [ -n "$UNEXPECTED" ]; then
    echo "ERROR: the bundled helper links non-system libraries and would crash in dyld:" >&2
    printf '%s\n' "$UNEXPECTED" | sed 's/^/    /' >&2
    exit 1
fi
echo "    helper is self-contained"

# Every non-system library the app itself loads must be inside the bundle, or the app
# will not launch on anyone else's Mac.
APP_BIN="$APP_PATH/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
DANGLING=""
for dep in $(non_system_deps "$APP_BIN"); do
    case "$dep" in
        @rpath/*)        top="${dep#@rpath/}";         top="${top%%/*}" ;;
        @executable_path/*) top="$(dirname "${dep#@executable_path/}")" ;;
        *)               top="" ;;
    esac
    if [ -n "$top" ] && [ -e "$APP_PATH/Contents/Frameworks/$top" ]; then
        continue
    fi
    DANGLING="$DANGLING$dep\n"
done
if [ -n "$DANGLING" ]; then
    echo "ERROR: the app depends on libraries that are not in the bundle:" >&2
    printf '%b' "$DANGLING" | sed 's/^/    /' >&2
    echo "    (a SwiftPM dynamic product must be embedded — see the Embed Frameworks phase)" >&2
    exit 1
fi
echo "    app dependencies resolve inside the bundle"
codesign -dv "$APP_PATH" 2>&1 | grep -E "Identifier|TeamIdentifier" || true

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Staging"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# A short note in the window; the README lives in the repo, not on the disk image.
cat >"$STAGING/Read me first.txt" <<'TXT'
AutoFansMac

1. Drag AutoFansMac to Applications.
2. Move it out of the disk image before launching: the privileged helper's launch path is
   fixed to /Applications/AutoFansMac.app, so fan control will not work from elsewhere.
3. Launch it and choose Install helper when asked (one administrator password).

Reading sensors needs no privileges. The app makes no network connections.
TXT

mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f "$OUTPUT_DMG"

echo "==> Building $OUTPUT_DMG"
hdiutil create \
    -volname "AutoFansMac" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$OUTPUT_DMG" >/dev/null

echo "==> Signing the disk image"
if codesign --sign "Developer ID Application" --timestamp "$OUTPUT_DMG" 2>/dev/null; then
    echo "    signed"
else
    echo "    no Developer ID identity available — left unsigned"
fi

echo
echo "Built: $OUTPUT_DMG"
echo "Notarise it with: xcrun notarytool submit \"$OUTPUT_DMG\" --keychain-profile <profile> --wait"
