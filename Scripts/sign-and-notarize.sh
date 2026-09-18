#!/usr/bin/env bash
#
# Scripts/sign-and-notarize.sh — Developer ID signing and notarisation for distribution.
#
# Usage:  Scripts/sign-and-notarize.sh [--archive]
#
#   --archive   also produce a zip suitable for `xcrun notarytool submit`
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in the login keychain for the team.
#   2. Notary credentials stored in the keychain:
#        xcrun notarytool store-credentials AutoFansMacNotary \
#            --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# The helper is signed with the same identity as the app: the daemon validates its client
# by team identifier and bundle id, so a mismatch means every XPC connection is refused.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TEAM_ID="${TEAM_ID:-93WWDR82K2}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-AutoFansMacNotary}"
BUNDLE_ID="com.autofansmac.AutoFansMac"
HELPER_NAME="AutoFansMacHelper"

BUILD_DIR="$REPO_ROOT/build/release"
APP_PATH="$BUILD_DIR/Build/Products/Release/AutoFansMac.app"
ZIP_PATH="$REPO_ROOT/build/AutoFansMac.zip"

echo "==> Archiving (Release, Developer ID)"
xcodebuild \
    -project AutoFansMac.xcodeproj \
    -scheme AutoFansMac \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    archive -archivePath "$REPO_ROOT/build/AutoFansMac.xcarchive"

ARCHIVE_APP="$REPO_ROOT/build/AutoFansMac.xcarchive/Products/Applications/AutoFansMac.app"
if [ ! -d "$ARCHIVE_APP" ]; then
    echo "Archive did not produce an app at $ARCHIVE_APP" >&2
    exit 1
fi

echo
echo "==> Verifying signatures (inside-out)"
HELPER="$ARCHIVE_APP/Contents/Library/LaunchDaemons/$HELPER_NAME"
codesign --verify --strict --verbose=2 "$HELPER"
codesign --verify --strict --verbose=2 "$ARCHIVE_APP"
codesign -dv --verbose=4 "$ARCHIVE_APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority|flags"
echo "    hardened runtime: $(codesign -dv "$ARCHIVE_APP" 2>&1 | grep -c 'flags=.*runtime') (1 = enabled)"

echo
echo "==> Notarising"
if [ "${1:-}" = "--archive" ] || [ "${1:-}" = "" ]; then
    ditto -c -k --keepParent "$ARCHIVE_APP" "$ZIP_PATH"
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait
    xcrun stapler staple "$ARCHIVE_APP"
    xcrun stapler validate "$ARCHIVE_APP"
    echo "    stapled and validated: $ARCHIVE_APP"
fi

echo
echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$ARCHIVE_APP" || true

echo
echo "Signed and notarised app: $ARCHIVE_APP"
echo "Next: Scripts/package-dmg.sh \"$ARCHIVE_APP\""
