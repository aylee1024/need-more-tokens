# Keychain-prompt elimination — root cause, fix, and verification

**Date:** 2026-06-20. **Goal:** NMT must never produce a recurring macOS Keychain prompt — once and for all — while staying fully native (no codexbar dependency).

## Root cause (traced + verified on-machine, not guessed)

NMT reads two login-Keychain items it does not own — `Claude Code-credentials/<user>` (Claude Code) and `gemini/antigravity` (Antigravity/`agy`). macOS prompts whenever the *requesting* app's code signature (its designated requirement) is not in the item's ACL. The prompt recurred because:

1. **Signature churn.** The app's signing identity flip-flopped ad-hoc ↔ Apple Development across fixes. Each change altered the designated requirement and invalidated every prior "Always Allow" ACL grant.
2. **A stale persisted setting.** `SettingsPaneView` seeded every provider's data-source picker with `DataSourcePolicy.auto`, which routes *native*. So Claude+Gemini were read natively (Keychain) before any durable grant existed.

Verified facts:
- Both Keychain items are updated **in place** (`Claude Code-credentials` created 2026-05-08, modified continuously) — the ACL is preserved across token refreshes, so a one-time grant is durable *if the signature stops changing*.
- Claude Code stores its token **only** in the Keychain (no file). The `~/.gemini/oauth_creds.json` file is **stale-prone** (agy refreshes the Keychain item, not the file), so the Keychain is Gemini's live source too.
- The app is **not sandboxed**, so it may read other apps' items, gated only by the ACL prompt.

## The keystone (empirically verified on macOS 26)

`SecKeychainSetUserInteractionAllowed(false)` — the legacy daemon API — makes a Keychain read **return an error instead of presenting the prompt**. Verified: with it set, reading an un-granted item returned `errSecAuthFailed (-25293)` instantly, no dialog, no hang. (The modern `kSecUseAuthenticationUI = …UIFail` query flag does **not** suppress the legacy ACL prompt — it governs only data-protection/biometric UI. Confirmed by the review panel and consistent with the test.)

So: with user interaction disabled process-wide, **a background refresh can never prompt**. That is the OS-level guarantee.

## Design

- **Keystone:** call `SecKeychainSetUserInteractionAllowed(false)` at launch and defensively before every background fetch. No background prompt is possible.
- **Seed-once:** an explicit "Enable native access" action briefly re-enables interaction, does one throwaway read per Keychain provider (the user clicks "Always Allow" once each), then disables interaction again. The only prompt the user ever sees, and they trigger it.
- **Friendly state:** an un-granted read maps to `CredentialAccessError.accessNotGranted`, so a card shows "Enable native access in Settings" instead of a cryptic error.
- **Signing pinned:** `build.sh --install` requires a stable identity and **fails** rather than falling back to ad-hoc, so the grant is never wiped by churn. `project.yml` comments reconciled to the true story.
- **Native defaults:** `defaultPolicy` → native for all three providers; codexbar fallback off by default (codexbar retired from the default path, kept as a manual per-provider option). Stale "NMT doesn't read the Keychain" comments removed.

## Status codes referenced
- `errSecSuccess` 0 · `errSecAuthFailed` -25293 · `errSecItemNotFound` -25300 · `errSecInteractionNotAllowed` -25308

## Build log
- 2026-06-20: root-caused via on-machine evidence + Codex/Gemini panel (panel split on the suppression mechanism; resolved empirically — `SecKeychainSetUserInteractionAllowed` is the real suppressor). Implementing keystone + seed flow + signing pin + native defaults.
