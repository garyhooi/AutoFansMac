#!/usr/bin/env bash
#
# Scripts/test.sh — run every automated suite.
#
#   1. SMCKitTests (SwiftPM, no Xcode project needed): struct layout, codec vectors, the
#      five unlock scenarios driven by MockSMC + a virtual clock.
#   2. AutoFansMacTests (xcodebuild test): curve math, profiles/migration, thermal floor,
#      RPM clamping.
#
# Hardware access is never required: everything that touches AppleSMC sits behind the
# SMCAccess protocol and is driven by MockSMC in tests.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="${TMPDIR:-/tmp}/autofansmac-tests"
mkdir -p "$LOG_DIR"
APP_LOG="$LOG_DIR/app-tests.log"

# Tests build into a scratch derived-data directory rather than the developer's own.
# Two reasons, both learned the hard way:
#   * codesign fails with "Command CodeSign failed with a nonzero exit code" when the app
#     is already running from Xcode's DerivedData, which makes an unrelated test run look
#     like a broken build;
#   * a test run must not overwrite the build products of the app you are currently
#     running (or worse, of one you are about to debug).
TEST_DERIVED_DATA="${TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/autofansmac-tests/DerivedData}"

failures=0

echo "==> SMCKit (SwiftPM)"
if (cd Packages/SMCKit && swift test); then
    echo "    SMCKit: PASS"
else
    echo "    SMCKit: FAIL"
    failures=$((failures + 1))
fi

echo
echo "==> AutoFansMac app tests (xcodebuild)"
xcodebuild \
    -project AutoFansMac.xcodeproj \
    -scheme AutoFansMac \
    -configuration Debug \
    -derivedDataPath "$TEST_DERIVED_DATA" \
    test >"$APP_LOG" 2>&1
app_status=$?

grep -E "error:|Executed .* tests|TEST (SUCCEEDED|FAILED)" "$APP_LOG" | tail -20 || true
if [ "$app_status" -ne 0 ]; then
    echo "    app tests: FAIL (full log: $APP_LOG)"
    if grep -q "Command CodeSign failed" "$APP_LOG"; then
        echo "    hint: a codesign failure usually means a copy of the app is running. Quit it"
        echo "          and re-run, or set TEST_DERIVED_DATA to a directory Xcode does not use."
    fi
    failures=$((failures + 1))
else
    echo "    app tests: PASS (full log: $APP_LOG)"
fi

echo
if [ "$failures" -ne 0 ]; then
    echo "==> $failures suite(s) failed"
    exit 1
fi
echo "==> All suites passed"
