#!/usr/bin/env bash
# Build + install NeedMoreTokens.
#
# Signing: leave it AD-HOC for local use (the default here). Ad-hoc, locally-built,
# non-quarantined apps launch fine via Finder/`open`/login items, and the Keychain
# re-prompt issue is already handled by routing Claude through codexbar (NMT never
# reads the Keychain in the default config), so a "stable" signature buys nothing.
#
# NMT_SIGN_IDENTITY (a codesigning identity from `security find-identity -v -p
# codesigning`) optionally re-signs the product. ONLY use a **Developer ID Application**
# identity here, and notarize, if you actually distribute the app. Do NOT use an
# "Apple Development" cert: Gatekeeper REJECTS it (spctl: rejected), so the app gets
# killed when launched via `open`/LaunchServices/login item and never reaches the menu
# bar (it only runs when executed directly by path). Unset = ad-hoc = the right choice
# for local use. No personal identity is committed to this repo.
#
# Usage: scripts/build.sh            # build (ad-hoc unless NMT_SIGN_IDENTITY set)
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
