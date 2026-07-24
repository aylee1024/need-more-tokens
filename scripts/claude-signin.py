#!/usr/bin/env python3
"""One-time Claude sign-in for NeedMoreTokens.

NMT holds its OWN Claude OAuth token so it never reads Claude Code's Keychain item
(that read is what kept getting evicted). Anthropic rotates the refresh token on every
refresh AND caps the grant's absolute lifetime, so the token eventually expires no
matter how healthy the rotation is. When it does, the Claude card says
"Claude sign-in expired" and this script mints a new token.

Usage:  python3 scripts/claude-signin.py

It prints an authorize URL, you approve in the browser, paste back the code Anthropic
shows, and it writes ~/.config/needmoretokens/claude-token.json (0600).
"""

import base64
import hashlib
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
AUTHORIZE_URL = "https://claude.com/cai/oauth/authorize"
TOKEN_URL = "https://api.anthropic.com/v1/oauth/token"
REDIRECT_URI = "https://platform.claude.com/oauth/code/callback"
# The full session scope. A token minted without user:profile 403s on /api/oauth/usage,
# which is why `claude setup-token` cannot be used here.
SCOPE = "user:inference user:mcp_servers user:profile user:sessions:claude_code"
TOKEN_PATH = os.path.expanduser("~/.config/needmoretokens/claude-token.json")
USER_AGENT = "claude-cli/2.1.185 (external, cli)"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def authorize_url(verifier: str) -> str:
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    query = urllib.parse.urlencode(
        {
            "code": "true",
            "client_id": CLIENT_ID,
            "response_type": "code",
            "redirect_uri": REDIRECT_URI,
            "scope": SCOPE,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": verifier,
        }
    )
    return f"{AUTHORIZE_URL}?{query}"


def exchange(code: str, state: str, verifier: str) -> dict:
    body = json.dumps(
        {
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": CLIENT_ID,
            "redirect_uri": REDIRECT_URI,
            "code_verifier": verifier,
        }
    ).encode()
    request = urllib.request.Request(
        TOKEN_URL,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        sys.exit(f"Token exchange failed: HTTP {error.code} {detail}")


def subscription_type(access_token: str) -> str | None:
    """Plan label for the card, read from the profile endpoint. Best effort."""
    request = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/profile",
        headers={
            "Authorization": f"Bearer {access_token}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            profile = json.loads(response.read())
    except Exception:
        return None
    account = profile.get("account") or {}
    if account.get("has_claude_max"):
        return "max"
    if account.get("has_claude_pro"):
        return "pro"
    return None


def save(token: dict) -> None:
    os.makedirs(os.path.dirname(TOKEN_PATH), mode=0o700, exist_ok=True)
    temporary = TOKEN_PATH + ".tmp"
    handle = os.open(temporary, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with open(handle, "w") as file:
        json.dump(token, file)
    os.replace(temporary, TOKEN_PATH)
    os.chmod(TOKEN_PATH, 0o600)


def main() -> None:
    verifier = b64url(secrets.token_bytes(32))
    print("\n1. Open this URL and approve:\n")
    print(authorize_url(verifier))
    print("\n2. Anthropic shows a code that looks like  <code>#<state>")
    pasted = input("\nPaste it here: ").strip()
    if not pasted:
        sys.exit("No code entered.")
    code, _, state = pasted.partition("#")
    payload = exchange(code.strip(), state.strip() or verifier, verifier)

    access = payload.get("access_token")
    refresh = payload.get("refresh_token")
    if not access or not refresh:
        sys.exit(f"Unexpected token response keys: {sorted(payload)}")

    token = {
        "access_token": access,
        "refresh_token": refresh,
        "client_id": CLIENT_ID,
        "expires_at": time.time() + payload.get("expires_in", 28_800),
        "subscription_type": subscription_type(access),
        "scope": payload.get("scope", SCOPE),
    }
    save(token)
    print(f"\nWrote {TOKEN_PATH} (0600).")
    print(f"Plan: {token['subscription_type'] or 'unknown'}   "
          f"access token valid ~{int(payload.get('expires_in', 28_800) / 3600)}h")
    print("Restart NeedMoreTokens (or wait for its next refresh) and the Claude card returns.")


if __name__ == "__main__":
    main()
