# Need More Tokens — Build Log

Plan of record: `~/.claude/plans/create-a-mac-desktop-inherited-flame.md` (approved 2026-06-06).

A native macOS 26 menu-bar app + desktop widget (SwiftUI, Liquid Glass) showing
Claude / Codex / Gemini 5-hour + weekly usage and API cost (cycle + lifetime),
built as a presentation layer over the `codexbar` engine (consumed via its CLI
JSON, so `brew upgrade codexbar` delivers upstream fixes with zero code change).

## Milestones
- [ ] M1 — Skeleton: repo + project.yml (3 targets) + Package.swift + minimal app/widget that launch
- [ ] M2 — Engine read path: BinaryLocator + ProcessClient + Raw/Domain models + EngineMapper + tests on real fixtures
- [x] M3 — Refresh + snapshot + first live menu-bar UI (working vertical slice) — app builds + runs + shows all 3 providers live
- [ ] M4 — Lifetime ledger (GRDB): schema + Reconciler + 365 backfill + exhaustive tests
- [ ] M5 — Liquid Glass polish: popover, status-icon modes, Settings, estimated-cost chips
- [ ] M6 — Widget extension: SingleProvider + AllThree, App-Intent config, gallery visibility
- [ ] M7 — Onboarding: binary-missing + provider-disabled flows
- [ ] M8 — Optional perf mode: codexbar serve client
- [ ] M9 — Harden + distribute: launch-at-login, CI, notarized release, homebrew tap

## Log

### 2026-06-06 — M1 start
- Verified machine: macOS 26.4, Xcode 26.2, Swift 6.2.3.
- Installed tooling: xcodegen 2.45.4 (arm64_tahoe), codexbar 0.32.0 (cask; CLI at /opt/homebrew/bin/codexbar).
- Created repo skeleton at ~/need-more-tokens, git init (main).
- Captured real codexbar usage/cost JSON for all 3 providers (Andrew approved the Claude Keychain prompt). Raw captures kept in /tmp only (PII); committed fixtures are sanitized.

### 2026-06-06 — M2 decode/mapper core (DONE, 16 tests green)
- Grounding corrections from real data:
  - Window periods are provider-specific: Codex/Claude = 5h(300)+weekly(10080); **Gemini = 3× daily(1440)**. Mapper labels by real `windowMinutes`, never hardcodes.
  - **`codexbar cost` supports only Claude + Codex** (Gemini returns an error / provider "cli"). Gemini cost is surfaced as honest "n/a", not $0.
  - Claude usage carries an **exact** `providerCost` monthly cap (used/limit), distinct from the estimated token×price `cost` (source "local" ⇒ estimated).
  - Output framing is a JSON array (NDJSON fallback retained for resilience).
- Files: `AppGroup/AppGroup.swift`, `Engine/RawEngineModels.swift` (tolerant decode + array/NDJSON framing), `Models/DomainModels.swift`, `Engine/EngineMapper.swift`.
- Tests: `Tests/.../EngineDecodeTests.swift` (16 cases) + sanitized fixtures. `swift test` green.
- Pending in M1/M2: `project.yml` + minimal app/widget shell (M1 gate), `BinaryLocator` + `ProcessClient` (live spawn), then multi-model review before first commit.

### 2026-06-07 — M2 live spawn + M3 visible slice (DONE)
- `EngineError`, `BinaryLocator` (incl. cask Helpers path + login-shell probe), `ProcessClient` (drain-without-deadlock + timeout→SIGTERM→SIGKILL + exit-code mapping), `EngineAdapter`, `WidgetSnapshot`/store. 24 Kit tests green incl. process spawn/timeout/large-output.
- **Real-world findings that changed the design (verified live):**
  - One-time Keychain "Allow" makes codexbar **re-prompt every spawn** → a single `--provider all` call hangs if Claude's prompt is unanswered. **Switched to per-provider concurrent fetch** so one provider's hang/slowness never blocks the others (partial results).
  - Running **all 3 codexbar instances at once makes Codex usage time out** (contention). **Capped concurrency at 2** → all three return.
  - `containerURL(forSecurityApplicationGroupIdentifier:)` returns a path even without the entitlement; must ensure the dir exists or the snapshot write silently fails. Fixed.
  - `MenuBarExtra` label `.task` does not fire → start the refresh loop from an `AppDelegate.applicationDidFinishLaunching`.
- App: SwiftUI `MenuBarExtra(.window)` + Liquid Glass popover (`GlassEffectContainer` + per-card `.glassEffect`), status item = lowest-remaining %. Builds clean against macOS 26.2 SDK; runs; **all 3 providers live** (Claude 3 windows/$1201 est, Codex 2 windows/$219 est, Gemini 3 daily/cost n/a).
- Installed to /Applications for use. Snapshot writes to `~/Library/Group Containers/group.com.aylee1024.needmoretokens/`.
- TODO before commit: remove stderr diagnostic writes; multi-model review panel; then App Group entitlement + widget (M6) + ledger (M4) + glass polish (M5).
- **Open action for Andrew:** grant the Claude Keychain item "Always Allow" so Claude doesn't re-prompt each refresh.

### 2026-06-07 — Andrew feedback round 1
- **Claude two weeklies fixed.** Grounded in codexbar `docs/claude.md`: `five_hour`→5-hour, `seven_day`→Weekly, `seven_day_opus/sonnet`→model-specific weekly. Now labeled **"Weekly"** + **"Weekly · Opus"**. Window labels are provider+position-aware in `EngineMapper.windowLabel` (+ `RateWindow.label`).
- **Gemini labels fixed + dug deep.** Per codexbar `docs/gemini.md`, the engine reads the **Code Assist** quota API (`cloudcode-pa.googleapis.com/...retrieveUserQuota`), mapping primary→Pro, secondary→Flash, tertiary→Flash Lite — the SAME quota as the CLI `/model` screen. Relabeled **Pro / Flash / Flash Lite** (was "Daily ×3"). The Gemini *web* "Usage limits" page is a different product (consumer Gemini app), which is why it stays 0% under CLI use. Our app reads the correct quota.
- **UI: replaced MenuBarExtra with NSStatusItem + `NMTPanel` (NSPanel).** Resizable (edge-drag), **persistent** size+position (`setFrameAutosaveName`), **sticky** (`hidesOnDeactivate=false` → no auto-dismiss; Esc or status-item toggle closes), movable by background. Popover content now flexible-width + scrollable. Status item shows colored lowest-remaining %.
- Removed stderr debug diagnostics. 26 Kit tests green. App builds + runs; snapshot labels verified (claude 5-hour/Weekly/Weekly·Opus, gemini Pro/Flash/Flash Lite).
- Still uncommitted. Multi-model review panel runs before first commit.

### 2026-06-07 — Andrew feedback round 2 (in progress)
- **Ground truth from the labeled Anthropic OAuth usage API** (`GET /api/oauth/usage`, read directly): `five_hour` 2%, `seven_day` 45%, `seven_day_opus`=**null**, `seven_day_sonnet`=**1%**, `extra_usage` used $0 / limit 4000¢ ($40) USD. So the second weekly is **Sonnet** (Andrew was right; my "Opus" was a wrong guess — codexbar collapses opus/sonnet into one slot). Fix: read the labeled endpoint directly for Claude windows so the model name is always account-accurate; codexbar fallback.
- **Subscription prices** (research + Andrew): Claude Max $100 (5×)/$200 (20×) [tier TBD, default $200]; Codex **Pro 5× = $100/mo** (matches codexbar plan "Pro 5x"); Gemini **Google AI Pro $19.99/mo**. Codex credits balance = 1000 (token-credit billing since Apr 2026).
- Plan for this round: (1) Claude direct-API windows + correct Sonnet/Opus label; (2) surface Daily Routines + credits (spent/balance); (3) replace confusing token "cycle cost" with monthly subscription $; (4) persistent UI-scale toggle (fonts + layout). Then Opus + Codex hardening before commit.

### 2026-06-07 — Opus + Codex hardening panel (applied)
Ran 2 Codex (GPT-5.5 xhigh: Integration + Domain) + 1 Opus skeptic, all grounded in CLAUDE.md + BUILD_LOG. Findings + resolution:
- **BLOCKER (Opus, verified on real Keychain): third-party token leak.** My `ClaudeUsageFetcher` fuzzy "first key containing access" grabbed a token from the `mcpOAuth` subtree (GitHub/Slack/… — 100% wrong in the repro) and sent it to api.anthropic.com. Also meant the enrichment never actually worked (wrong token → rejected → silent fallback).
- **HIGH (Codex Domain, contradicting Opus): the 8s timeout didn't work** — `withTaskGroup` awaits children; the operation awaited a non-cancellable detached `SecItemCopyMatching`, so a Keychain prompt still stalled refresh.
- **Resolution: REMOVED the Claude direct-API entirely** (SIMPLICITY-FIRST; it gave zero current value — the default "Weekly · Sonnet" is already correct, verified via the labeled API: opus=null, sonnet=1%). Eliminates the security surface, the blocking, and a second Keychain consumer.
- **Applied:** decode-tolerant `WidgetSnapshot.Entry` (BLOCKER 2 — old snapshots no longer silently empty the widget); `tightestWindow` now includes extra windows; per-provider error message surfaced in UI; `firstOfMonthDayKey` anchor-day bug fixed + clamped; **cost spawns gated OFF** (not rendered → faster refresh ~45s→~12s, less contention); ProcessClient drain-timeout no longer returns truncated success; Gemini price guarded against missing plan; status-item font scales with the UI-size toggle; panel frame clamped to current screen; 0%-bar sliver fixed; credits sanitized; weak-self in observation; snapshot-save failure surfaced.
- **32 Kit tests green** (added: token-extraction-ignores-mcpOAuth regression, decode-tolerance regression, billing-anchor cases). App builds + runs; all 3 providers live; refresh ~12s.
- **Deferred (noted, low-impact):** process-group kill of codexbar children; cost timezone alignment (moot while cost off); App Group entitlements (M6 widget).
- **OPEN for Andrew:** (a) confirm Claude Max tier — $100 (5×) vs $200 (20×), currently defaulting $200; (b) permission to make the first git commit (nothing committed yet, per review-before-commit).

### 2026-06-07 — Shipped to GitHub
- Initial commit `f3d6074` (32 files, no artifacts/secrets). Pushed to **https://github.com/aylee1024/need-more-tokens** — public, MIT, topics set.
- New short/fun README framing it as the companion to **lord-claude** (Andrew's Claude→Codex/Gemini delegation skills).
- STILL OPEN: Claude tier ($100/$200); next milestones = M4 lifetime ledger + M6 widget (needs App Group entitlements on both targets).
