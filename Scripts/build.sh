#!/usr/bin/env bash
#
# Scripts/build.sh — build the app, the helper, and the CLI in Release configuration.
#
# Usage:  Scripts/build.sh [--debug] [--unsigned]
#
#   --debug      build Debug instead of Release
#   --unsigned   add CODE_SIGNING_ALLOWED=NO (useful on a machine with no identity, but
#                the resulting app cannot install or talk to the privileged helper)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="Release"
EXTRA_SETTINGS=()

for arg in "$@"; do
    case "$arg" in
        --debug)    CONFIGURATION="Debug" ;;
        --unsigned) EXTRA_SETTINGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO) ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

echo "==> Building SMCKit (${CONFIGURATION})"
(cd Packages/SMCKit && swift build -c "$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')")

echo
echo "==> Building afmctl"
(cd Tools/afmctl && swift build -c "$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')")

echo
echo "==> Building AutoFansMac.app + AutoFansMacHelper (${CONFIGURATION})"
xcodebuild \
    -project AutoFansMac.xcodeproj \
    -scheme AutoFansMac \
    -configuration "$CONFIGURATION" \
    build \
    "${EXTRA_SETTINGS[@]+"${EXTRA_SETTINGS[@]}"}"

APP_PATH="$(xcodebuild -project AutoFansMac.xcodeproj -scheme AutoFansMac -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/AutoFansMac.app"

echo
echo "==> Built: $APP_PATH"
echo "    helper: $(ls -l "$APP_PATH/Contents/Library/LaunchDaemons/" 2>/dev/null | tail -n +2 | awk '{print $NF}' | tr '\n' ' ')"
if command -v codesign >/dev/null; then
    echo "    signature: $(codesign -dv "$APP_PATH" 2>&1 | grep -E '^Authority' | head -1 | cut -d= -f2-)"
fi
