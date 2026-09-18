#!/usr/bin/env bash
#
# Scripts/dev-install-helper.sh — development fallback for installing the privileged
# LaunchDaemon without SMAppService.
#
# Why this exists: `SMAppService.daemon(plistName:)` requires a signed app AND a
# LaunchDaemon plist whose ProgramArguments is an absolute path. The plist shipped in the
# bundle points at /Applications/AutoFansMac.app, so it only matches the canonical install
# location. For a throwaway build — ad-hoc signing, a build under DerivedData, CI — this
# script writes a plist that points at the helper where it actually is and bootstraps it
# with launchd directly.
#
# Usage:
#   Scripts/dev-install-helper.sh install [path/to/AutoFansMac.app] [--allow-untrusted]
#   Scripts/dev-install-helper.sh status
#   Scripts/dev-install-helper.sh uninstall
#
# The app still has to be able to talk to the daemon: it validates the connecting
# client's code signature against the team identifier in Shared/HelperProtocol.swift.
# A build signed with your team's Apple Development or Developer ID certificate satisfies
# that on its own — including an Xcode Run build — so nothing extra is needed.
#
# Only an AD-HOC-signed (or unsigned) build fails that check. For that case pass
# --allow-untrusted, which adds AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS=1 to the plist. A DEBUG
# helper and the unsigned community build (Scripts/package-unsigned.sh) honour it; a
# Developer ID Release helper ignores it. Never leave that in place on a signed build.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_ID="com.autofansmac.AutoFansMac.helper"
HELPER_NAME="AutoFansMacHelper"

INSTALL_DIR="/Library/PrivilegedHelperTools"
PLIST_DEST="/Library/LaunchDaemons/${HELPER_ID}.plist"

ORIGINAL_ARGS=("$@")

ACTION="${1:-status}"
shift 2>/dev/null || true

# Options and an optional app path are parsed explicitly. Do NOT treat "$2" as a path
# blindly: a stray word (a comment copied along with the command, an unknown flag) would
# otherwise be used as the bundle location and produce a confusing "no helper at ...".
ALLOW_UNTRUSTED="no"
APP_ARG=""
for arg in "$@"; do
    case "$arg" in
        --allow-untrusted) ALLOW_UNTRUSTED="yes" ;;
        -h|--help)         ACTION="help" ;;
        -*)                echo "unknown option: $arg" >&2; exit 2 ;;
        *)                 APP_ARG="$arg" ;;
    esac
done

# A launchd daemon is copied out of the app bundle, so every library it loads has to
# come from the system. A SwiftPM library product linked as a dynamic framework leaves a
# dependency on DerivedData/PackageFrameworks, and the daemon then crash-loops in dyld
# (OS_REASON_DYLD) with launchd reporting "successive crashes" and no XPC endpoint.
check_self_contained() {
    local binary="$1"
    local unexpected
    # `otool -L` prints a "path (architecture):" header per slice for fat binaries, so
    # headers and blank lines are dropped before looking at dependencies.
    unexpected="$(otool -L "$binary" \
        | grep -v ':$' | grep -v '^[[:space:]]*$' \
        | sed 's/^[[:space:]]*//; s/ (compatibility.*$//; s/ (architecture.*$//' \
        | grep -vE '^(/usr/lib|/System/Library)' || true)"

    if [ -n "$unexpected" ]; then
        cat >&2 <<MSG
ERROR: $HELPER_NAME is not self-contained — it would crash in dyld when launchd starts it.

These libraries are not part of the system:

$(printf '%s\n' "$unexpected" | sed 's/^/    /')

That is what a SwiftPM library product linked as a dynamic framework looks like. Declare
the product static in Packages/SMCKit/Package.swift:

    .library(name: "SMCKit", type: .static, targets: ["SMCKit"])

then do Product -> Clean Build Folder in Xcode (a stale link line survives incremental
builds) and re-run this script.
MSG
        return 1
    fi
    return 0
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This action needs root. Re-run with sudo:" >&2
        echo "    sudo $0 ${ORIGINAL_ARGS[*]}" >&2
        exit 1
    fi
}

# Echoes an existing AutoFansMac.app: the explicit argument if it is a real bundle,
# otherwise the newest Debug build under DerivedData.
find_app() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        if [ -d "$explicit" ]; then
            echo "$explicit"
            return
        fi
        echo "Not a directory: $explicit" >&2
        echo "Pass the path to an AutoFansMac.app, or omit it to use the newest Debug build." >&2
        exit 1
    fi

    local app
    # Newest first, so a stale DerivedData directory cannot win.
    app="$(/usr/bin/find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 \
        -name "AutoFansMac.app" -path "*Debug*" -print0 2>/dev/null \
        | xargs -0 ls -dt 2>/dev/null | head -1)"
    if [ -z "$app" ] || [ ! -d "$app" ]; then
        echo "Could not find a Debug AutoFansMac.app under DerivedData." >&2
        echo "Build it first, or pass the path: $0 install /path/to/AutoFansMac.app" >&2
        exit 1
    fi
    echo "$app"
}

# Echoes the newest built helper, so status can say whether a build is installable
# before anything is copied into /Library.
find_built_helper() {
    local app
    app="$(find_app "" 2>/dev/null || true)"
    [ -n "$app" ] || return 0
    [ -x "$app/Contents/Library/LaunchDaemons/$HELPER_NAME" ] || return 0
    echo "$app/Contents/Library/LaunchDaemons/$HELPER_NAME"
}

case "$ACTION" in
    install)
        APP="$(find_app "$APP_ARG")"
        HELPER_SRC="$APP/Contents/Library/LaunchDaemons/$HELPER_NAME"
        if [ ! -x "$HELPER_SRC" ]; then
            echo "No helper at $HELPER_SRC — build the AutoFansMacHelper target first." >&2
            exit 1
        fi

        check_self_contained "$HELPER_SRC" || exit 1

        require_root "$@"

        echo "==> Installing $HELPER_NAME"
        echo "    source: $HELPER_SRC"
        mkdir -p "$INSTALL_DIR"
        install -m 0755 -o root -g wheel "$HELPER_SRC" "$INSTALL_DIR/$HELPER_NAME"

        # The daemon authorises clients by signing team, and additionally by exact bundle
        # identifier when one is configured here. It is read from the app we are installing
        # from, so it can never drift out of sync with the build that will connect to it —
        # hardcoding it once made the daemon refuse its own app, silently.
        APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$APP/Contents/Info.plist" 2>/dev/null || true)"
        if [ -z "$APP_BUNDLE_ID" ]; then
            echo "    WARNING: could not read CFBundleIdentifier from $APP/Contents/Info.plist;"
            echo "             the daemon will authorise by signing team only."
        else
            echo "    client identifier: $APP_BUNDLE_ID"
        fi

        ENVIRONMENT_BLOCK=''
        if [ "$ALLOW_UNTRUSTED" = "yes" ]; then
            echo "    WARNING: --allow-untrusted adds AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS=1."
            echo "             The daemon will accept clients from any signature — only DEBUG"
            echo "             and unsigned community builds honour this."
            ENVIRONMENT_BLOCK='    <key>EnvironmentVariables</key>
    <dict>
        <key>AUTOFANSMAC_ALLOW_UNTRUSTED_CLIENTS</key>
        <string>1</string>
    </dict>
'
        elif [ -n "$APP_BUNDLE_ID" ]; then
            ENVIRONMENT_BLOCK="    <key>EnvironmentVariables</key>
    <dict>
        <key>AUTOFANSMAC_EXPECTED_CLIENT</key>
        <string>${APP_BUNDLE_ID}</string>
    </dict>
"
        fi

        echo "==> Writing $PLIST_DEST"
        cat >"$PLIST_DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${HELPER_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/${HELPER_NAME}</string>
    </array>
${ENVIRONMENT_BLOCK}    <key>MachServices</key>
    <dict>
        <key>${HELPER_ID}</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>${APP_BUNDLE_ID:-com.autofansmac.AutoFansMac}</string>
    </array>
</dict>
</plist>
PLIST
        chown root:wheel "$PLIST_DEST"
        chmod 0644 "$PLIST_DEST"

        echo "==> Bootstrapping"
        launchctl bootout system "$PLIST_DEST" 2>/dev/null || true
        launchctl bootstrap system "$PLIST_DEST"
        launchctl print "system/${HELPER_ID}" | head -12 || true

        echo
        echo "Done. Launch the app and use Settings → Fan Control."
        echo "Logs: log stream --predicate 'process == \"${HELPER_NAME}\"' --level info"
        ;;

    status)
        echo "--- installed daemon ---"
        echo "plist:    $([ -f "$PLIST_DEST" ] && echo present || echo missing)  ($PLIST_DEST)"
        if [ -x "$INSTALL_DIR/$HELPER_NAME" ]; then
            echo "binary:   present  ($INSTALL_DIR/$HELPER_NAME)"
            if check_self_contained "$INSTALL_DIR/$HELPER_NAME" 2>/dev/null; then
                echo "deps:     self-contained"
            else
                echo "deps:     NOT self-contained — it crashes in dyld; reinstall from a clean build"
            fi
        else
            echo "binary:   missing  ($INSTALL_DIR/$HELPER_NAME)"
        fi
        echo "service:"
        launchctl print "system/${HELPER_ID}" 2>/dev/null \
            | grep -E "state = |runs = |successive crashes|last exit reason" \
            | sed 's/^/    /' || echo "    not loaded"

        echo
        echo "--- newest build ---"
        BUILT="$(find_built_helper)"
        if [ -z "$BUILT" ]; then
            echo "no Debug AutoFansMac.app found under DerivedData (build the app first)"
        else
            echo "helper:   $BUILT"
            if check_self_contained "$BUILT" 2>/dev/null; then
                echo "deps:     self-contained — safe to install"
            else
                echo "deps:     NOT self-contained — do a clean build before installing"
            fi
        fi
        ;;


    uninstall)
        require_root "$@"
        echo "==> Stopping and removing the dev helper"
        launchctl bootout system "$PLIST_DEST" 2>/dev/null || true
        rm -f "$PLIST_DEST"
        rm -f "$INSTALL_DIR/$HELPER_NAME"
        echo "Removed."
        ;;

    help|*)
        sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
        [ "$ACTION" = "help" ] && exit 0
        exit 2
        ;;
esac
