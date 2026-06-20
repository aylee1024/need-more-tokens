#!/usr/bin/env bash
# Build + install NeedMoreTokens.
#
# Signing: a STABLE code-signing identity keeps the app's designated requirement
# (DR) constant across rebuilds. NMT now reads agy's Gemini OAuth token from the
# login Keychain, so the one-time "Always Allow" grant must survive rebuilds — and
# that grant is keyed to the app's DR. Ad-hoc signatures are cdhash-based and change
# every build, so they re-prompt forever. This script therefore signs with a stable
# identity by default, preferring a Developer ID Application, then Apple Development.
#
# (Verified 2026-06-19 on this machine: an Apple-Development-signed, locally-built,
# NON-quarantined app launches fine via open/LaunchServices and reaches the menu bar.
# `spctl` reports "rejected" — that is the distribution/notarization assessment and
# does NOT block a local, non-quarantined launch. Notarize only if you distribute.)
#
# Override with NMT_SIGN_IDENTITY="<identity>"; force ad-hoc with NMT_SIGN_IDENTITY="-".
#
# Usage: scripts/build.sh            # build; auto-picks a stable identity (ad-hoc only if none found)
#        scripts/build.sh --install  # also copy to /Applications and relaunch (REQUIRES a stable identity)
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -scheme NeedMoreTokens -derivedDataPath build build

APP="build/Build/Products/Debug/NeedMoreTokens.app"

# Re-sign AFTER xcodebuild (which signs ad-hoc / "Sign to Run Locally") so the
# stable identity sticks. Auto-pick the best available identity unless overridden.
SIGN_ID="${NMT_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning | grep -oE '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
    [ -z "$SIGN_ID" ] && SIGN_ID="$(security find-identity -v -p codesigning | grep -oE '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)"
fi
SIGNED_STABLE=0
case "$SIGN_ID" in
    "" | "-" | adhoc)
        : ;;  # no stable identity resolved — handled below
    *)
        if security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
            codesign --force --deep --sign "$SIGN_ID" "$APP"
            SIGNED_STABLE=1
            echo "re-signed with stable identity ($SIGN_ID) — Keychain Always-Allow persists across rebuilds"
        else
            echo "identity '$SIGN_ID' not found"
        fi ;;
esac
codesign -dv "$APP" 2>&1 | grep -iE "flags|TeamIdentifier|Signature=" || true

if [ "$SIGNED_STABLE" = "0" ]; then
    echo "WARNING: no stable signing identity — app is ad-hoc; its designated requirement"
    echo "         changes every build, so any Keychain 'Always Allow' grant is wiped on rebuild."
fi

if [ "${1:-}" = "--install" ]; then
    # Fail closed: never install an ad-hoc build. An ad-hoc designated requirement changes
    # on every rebuild, which wipes NMT's Keychain ACL grant and brings back the recurring
    # prompt — the exact bug this is meant to end. Require a stable identity for installs.
    if [ "$SIGNED_STABLE" = "0" ]; then
        echo "ERROR: refusing to --install an ad-hoc build." >&2
        echo "       A stable code-signing identity is required so the Keychain 'Always Allow'" >&2
        echo "       grant survives rebuilds. Obtain an Apple Development or Developer ID identity" >&2
        echo "       (Xcode ▸ Settings ▸ Accounts), or set NMT_SIGN_IDENTITY=\"<identity name>\", then re-run." >&2
        exit 1
    fi
    pkill -f "/Applications/NeedMoreTokens.app" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/NeedMoreTokens.app
    cp -R "$APP" /Applications/
    open -a /Applications/NeedMoreTokens.app
    echo "installed to /Applications and relaunched"
fi
