#!/usr/bin/env bash
#
# Scripts/package-unsigned.sh — build a distributable DMG with NO Apple signing and NO
# notarization, for people who do not have a Developer ID certificate.
#
# Usage:  Scripts/package-unsigned.sh
#
# The result is a normal Release app carrying an AD-HOC signature, which macOS accepts
# once the download quarantine is cleared:
#
#     xattr -dr com.apple.quarantine /Applications/AutoFansMac.app
#
# Two consequences of having no certificate, both covered in Docs/DISTRIBUTING.md:
#
#   1. Gatekeeper refuses the first launch ("move to Trash") until that command runs.
#   2. The privileged helper authorises its client by signing team, and an ad-hoc build
#      has no team. So this build's helper is compiled with AUTOFANSMAC_UNSIGNED_BUILD
#      and the bundled LaunchDaemon plist carries
#      AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS=1, which makes the daemon accept any local
#      client. That is the whole reason fan control works here — and the whole reason a
#      signed Release build does not compile that branch.
#
# The helper installer travels inside the app, at
# Contents/Resources/install-helper.sh, so it survives the disk image being ejected.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="Release"
DERIVED="$REPO_ROOT/build/unsigned-derived"
STAGE="$REPO_ROOT/build/unsigned"
APP="$STAGE/AutoFansMac.app"

HELPER_NAME="AutoFansMacHelper"
PLIST_NAME="com.autofansmac.AutoFansMac.helper.plist"
PLIST="$APP/Contents/Library/LaunchDaemons/$PLIST_NAME"

non_system_deps() {
    # otool prints a "path (architecture):" header per slice for fat binaries.
    otool -L "$1" \
        | grep -v ':$' | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//; s/ (compatibility.*$//; s/ (architecture.*$//' \
        | grep -vE '^(/usr/lib|/System/Library)' || true
}

echo "==> Building (${CONFIGURATION}, unsigned, AUTOFANSMAC_UNSIGNED_BUILD)"
xcodebuild \
    -project AutoFansMac.xcodeproj \
    -scheme AutoFansMac \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="AUTOFANSMAC_UNSIGNED_BUILD" \
    build

BUILT_APP="$DERIVED/Build/Products/$CONFIGURATION/AutoFansMac.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "No app at $BUILT_APP" >&2
    exit 1
fi

echo
echo "==> Staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$BUILT_APP" "$APP"

if [ ! -x "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME" ]; then
    echo "The app has no privileged helper at Contents/Library/LaunchDaemons/$HELPER_NAME." >&2
    exit 1
fi

# The daemon reads this from its own environment (launchd sets it from the plist), and
# the unsigned-build helper honours it. Without it every XPC connection is refused,
# because an ad-hoc signature cannot satisfy "certificate leaf[subject.OU] = <team>".
echo "==> Allowing the helper to accept this unsigned app"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS 1" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS string 1" "$PLIST"

# SMAppService needs the app to be in /Applications; when that path is not available
# (or the button fails) the bundled installer writes the daemon's launchd job directly.
echo "==> Bundling the helper installer"
mkdir -p "$APP/Contents/Resources"
install -m 0755 "$REPO_ROOT/Scripts/dev-install-helper.sh" "$APP/Contents/Resources/install-helper.sh"

# Browsing the staging folder in Finder stamps com.apple.FinderInfo onto the bundle, and
# codesign then reports "resource fork, Finder information, or similar detritus not
# allowed" — the signature no longer verifies. Clearing the attributes before signing
# makes the build immune to how the folder was looked at.
echo "==> Clearing Finder metadata"
xattr -cr "$APP"

# Ad-hoc. Inside out, and *after* every edit above: touching Resources or the plist
# invalidates a signature.
echo "==> Ad-hoc signing (inside out)"
codesign --force --sign - "$APP/Contents/Frameworks/SMCKit.framework"
codesign --force --sign - "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME"
codesign --force --sign - "$APP"

echo "==> Checking the bundle"
codesign --verify --strict "$APP"
printf '    app:    '
codesign -dv "$APP" 2>&1 | grep -E '^Signature|^Identifier|^TeamIdentifier' | tr '\n' ' ' || true
echo "(adhoc = Signature=adhoc, no TeamIdentifier)"

UNEXPECTED="$(non_system_deps "$APP/Contents/Library/LaunchDaemons/$HELPER_NAME")"
if [ -n "$UNEXPECTED" ]; then
    echo "ERROR: the bundled helper links non-system libraries and would crash in dyld:" >&2
    printf '%s\n' "$UNEXPECTED" | sed 's/^/    /' >&2
    exit 1
fi
echo "    helper is self-contained"

APP_BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
DANGLING=""
for dep in $(non_system_deps "$APP_BIN"); do
    case "$dep" in
        @rpath/*)           top="${dep#@rpath/}"; top="${top%%/*}" ;;
        @executable_path/*) top="$(dirname "${dep#@executable_path/}")" ;;
        *)                  top="" ;;
    esac
    if [ -n "$top" ] && [ ! -e "$APP/Contents/Frameworks/$top" ]; then
        DANGLING="$DANGLING$dep\n"
    fi
done
if [ -n "$DANGLING" ]; then
    echo "ERROR: the app depends on libraries that are not in the bundle:" >&2
    printf '%b' "$DANGLING" | sed 's/^/    /' >&2
    exit 1
fi
echo "    app dependencies resolve inside the bundle"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 1.0)"
DMG="$REPO_ROOT/build/AutoFansMac-${VERSION}-unsigned.dmg"

echo
echo "==> Staging the disk image"
cat >"$STAGE/Read me first.txt" <<'TXT'
AutoFansMac — unsigned community build

1. Drag AutoFansMac to Applications, then eject this disk image.

2. Clear the download quarantine, or macOS will refuse to open the app and offer to move
   it to the Trash:

       xattr -dr com.apple.quarantine /Applications/AutoFansMac.app

3. Launch it. Reading sensors needs no privileges. Driving the fans does, so the app
   installs its privileged helper the first time you ask it to control a fan (one
   administrator password, then approve it in System Settings > General > Login Items).

   If the in-app install does not work, run this instead:

       sudo /Applications/AutoFansMac.app/Contents/Resources/install-helper.sh install /Applications/AutoFansMac.app --allow-untrusted

This build is NOT signed or notarized by Apple. That is why step 2 exists, and why the
helper accepts any local client: it has no certificate to check against. If you would
rather trust a signature, build it yourself (Scripts/package-unsigned.sh) or sign it
with your own Apple team (Docs/DISTRIBUTING.md).
TXT

ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
echo "==> Building $DMG"
hdiutil create \
    -volname "AutoFansMac" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG" >/dev/null

echo
echo "Built: $DMG"
echo "       $APP"
echo
echo "Users install it with:"
echo "    xattr -dr com.apple.quarantine /Applications/AutoFansMac.app"
echo
echo "Fan control additionally needs the helper:"
echo "    sudo /Applications/AutoFansMac.app/Contents/Resources/install-helper.sh install /Applications/AutoFansMac.app --allow-untrusted"
