#!/usr/bin/env bash
# Build NeedMoreTokens and re-sign with a stable identity so the macOS Keychain
# "Always Allow" grant for the Claude Code-credentials item (read by the native Claude
# client) persists across rebuilds. Ad-hoc signatures change hash every build, so the
# grant never sticks and macOS re-prompts on every refresh.
#
# Set NMT_SIGN_IDENTITY (a codesigning cert SHA-1 or name, per
#   security find-identity -v -p codesigning
# ) in your shell env (e.g. ~/.zprofile). If unset/not found, the app stays ad-hoc —
# fine for a quick run, but Keychain will re-prompt across rebuilds. No personal
# identity is committed to this repo.
#
# Usage: scripts/build.sh            # build + re-sign
#        scripts/build.sh --install  # also copy to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -scheme NeedMoreTokens -derivedDataPath build build

APP="build/Build/Products/Debug/NeedMoreTokens.app"

if [ -n "${NMT_SIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning | grep -q "$NMT_SIGN_IDENTITY"; then
    # Re-sign AFTER xcodebuild so nothing clobbers it.
    codesign --force --deep --sign "$NMT_SIGN_IDENTITY" "$APP"
    echo "re-signed with stable identity — Keychain Always-Allow will persist across rebuilds"
else
    echo "NMT_SIGN_IDENTITY unset or cert not found; app left ad-hoc (Keychain will re-prompt across rebuilds)"
fi
codesign -dv "$APP" 2>&1 | grep -iE "flags|TeamIdentifier|Signature=" || true

if [ "${1:-}" = "--install" ]; then
    pkill -f "/Applications/NeedMoreTokens.app" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/NeedMoreTokens.app
    cp -R "$APP" /Applications/
    open -a /Applications/NeedMoreTokens.app
    echo "installed to /Applications and relaunched"
fi
