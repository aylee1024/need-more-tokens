# NMT Gemini meter → Antigravity `agy` migration spec

**Status:** API fully reverse-engineered (mitmproxy capture of `agy`, 2026-06-18). Token storage = the one open item (encrypted in macOS Keychain; needs a `sudo fs_usage` trace to pinpoint the exact item). Captured via no-sudo mitmproxy (`agy` honors `SSL_CERT_FILE`; route `HTTPS_PROXY` + `SSL_CERT_FILE=~/.mitmproxy/...`).

## Why
gemini-cli / Code Assist for individuals retired 2026-06-18. NMT's `GeminiUsageClient` hit `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` with the `~/.gemini/oauth_creds.json` token — both dead. Antigravity `agy` is the replacement; this repoints NMT to agy's live backend.

## Live endpoints (ground truth from capture)
Host: **`daily-cloudcode-pa.googleapis.com`** (NOT the binary-strings guess `businessaicode`; the prod host may also be `cloudcode-pa.googleapis.com` — agy used `daily-`). All POST, `Authorization: Bearer ya29.<google-oauth-access-token>`, `Content-Type: application/json`.

1. **Project bootstrap** — `POST /v1internal:loadCodeAssist`
   - Request body: `{"metadata":{"ideType":"ANTIGRAVITY"}}`
   - Response: `{ "currentTier": {...}, "allowedTiers": [...], "cloudaicompanionProject": "<project>" }` (same `cloudaicompanionProject` field NMT already extracts). Observed project: `parabolic-zepplin-pw532`.

2. **Quota** — `POST /v1internal:retrieveUserQuotaSummary`
   - Request body: `{"project":"<cloudaicompanionProject>"}`
   - Response shape (REPLACES the old top-level `buckets[]`/`modelID` shape):
```json
{
  "groups": [
    {
      "displayName": "Gemini Models",
      "description": "Models within this group: Gemini Flash, Gemini Pro",
      "buckets": [
        { "bucketId": "gemini-weekly", "displayName": "Weekly Limit", "window": "weekly",
          "resetTime": "2026-06-25T23:03:46Z", "description": "...", "remainingFraction": 0.9849711 },
        { "bucketId": "gemini-5h", "displayName": "Five Hour Limit", "window": "5h",
          "resetTime": "2026-06-19T04:03:46Z", "description": "...", "remainingFraction": 0.96553755 }
      ]
    },
    { "displayName": "Claude and GPT models", "buckets": [ {"bucketId":"3p-weekly",...}, {"bucketId":"3p-5h",...} ] }
  ],
  "description": "..."
}
```

## Decoder mapping (GeminiUsageClient)
- New `RawGeminiQuotaPayload { groups: [RawGroup] }`, `RawGroup { displayName, description, buckets: [RawBucket] }`, `RawBucket { bucketId, displayName, window, resetTime, description, remainingFraction }`.
- NMT's Gemini meter = the group whose `displayName == "Gemini Models"` (or buckets whose `bucketId` starts `gemini-`). IGNORE the `3p-*` "Claude and GPT models" group (those are agy's other models, not the Gemini family).
- Per bucket → `RateWindow(label: displayName, period: window=="weekly" ? .weekly : .fiveHour, usedPercent: (1 - remainingFraction)*100, resetsAt: parseDate(resetTime), resetDescription: description)`.
- `window` is `"weekly"` or `"5h"`.

## Code changes
- `Sources/NeedMoreTokensKit/Net/Clients/GeminiUsageClient.swift`:
  - `retrieveQuotaURL` → `https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
  - `loadCodeAssistURL` → `https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
  - loadCodeAssist request body → `{"metadata":{"ideType":"ANTIGRAVITY"}}`
  - quota request body → `{"project": project}` (project required; from loadCodeAssist)
  - rewrite `RawGeminiQuotaPayload` + `windows(from:)` for the groups/buckets shape above.
- `Credentials/CredentialStore.swift` `loadGeminiAccess`: replace the `~/.gemini/oauth_creds.json` read with a read of agy's token (see Open item).
- Tests: `Tests/.../GeminiUsageClientTests.swift` — feed the captured JSON above; assert the two Gemini buckets map to weekly≈1.5% used / 5h≈3.4% used; assert `3p-*` group ignored.

## RESOLVED: token storage
agy stores its OAuth credential in the macOS **Keychain** via the Go `keyring` lib (github.com/zalando/go-keyring):
- Item: `kSecClassGenericPassword`, **service (`kSecAttrService`) = `gemini`**, **account (`kSecAttrAccount`) = `antigravity`**.
- Value (string): `go-keyring-base64:` + base64( JSON ). (The `go-keyring-base64:` prefix is go-keyring's marker for values it base64-wraps. Strip it, then base64-decode.)
- Decoded JSON:
```json
{ "token": { "access_token": "ya29.…", "token_type": "Bearer",
             "refresh_token": "1//…", "expiry": "2026-06-19T…Z" },
  "auth_method": "consumer" }
```
- (The `Antigravity Safe Storage` keychain item is just the 16-byte Electron safeStorage AES key — NOT the token. Ignore it.)

### NMT token read (CredentialStore.loadGeminiAccess)
1. `SecItemCopyMatching` for service `gemini` / account `antigravity` (kSecClassGenericPassword, returnData). First read triggers a one-time user "Always Allow" prompt — standard cross-app keychain pattern; thereafter silent.
2. Decode the UTF-8 string; if it starts with `go-keyring-base64:`, drop that prefix and base64-decode the remainder.
3. JSON-decode → `{ token: { access_token, token_type, refresh_token, expiry }, auth_method }`.
4. Use `token.access_token` as the Bearer. `expiry` is ISO-8601 → reuse the existing `CredentialExpiry` skew check; on expiry surface a "re-auth in Antigravity / run agy" message (agy refreshes the keychain itself; NMT mirrors whatever agy last stored). `refresh_token` is present if NMT ever needs to self-refresh against `oauth2.googleapis.com/token`.
5. The old `~/.gemini/oauth_creds.json` path (`defaultGeminiOAuthURL`/`loadGeminiOAuth`) is dead — replace its use in `loadGeminiAccess`; keep a file-based fallback only if you want graceful behavior on machines without agy.
