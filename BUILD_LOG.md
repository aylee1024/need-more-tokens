# Need More Tokens — Build Log

Plan of record: `~/.claude/plans/create-a-mac-desktop-inherited-flame.md` (approved 2026-06-06).

A native macOS 26 menu-bar app (SwiftUI, Liquid Glass) showing
Claude / Codex / Gemini 5-hour + weekly usage and API cost (cycle + lifetime),
built as a presentation layer over the `codexbar` engine (consumed via its CLI
JSON, so `brew upgrade codexbar` delivers upstream fixes with zero code change).

## Milestones
- [ ] M1 — Skeleton: repo + project.yml (3 targets) + Package.swift + minimal app/widget that launch
- [ ] M2 — Engine read path: BinaryLocator + ProcessClient + Raw/Domain models + EngineMapper + tests on real fixtures
- [x] M3 — Refresh + snapshot + first live menu-bar UI (working vertical slice) — app builds + runs + shows all 3 providers live
- [ ] M4 — Lifetime ledger (GRDB): schema + Reconciler + 365 backfill + exhaustive tests
- [ ] M5 — Liquid Glass polish: popover, status-icon modes, Settings, estimated-cost chips
- [~] M6 — Widget extension — **DROPPED 2026-06-10** (scope reduced to the menu bar; the `WidgetSnapshot` model stays as the app's own data model)
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

### 2026-06-07 — UI-size toggle was a no-op on macOS (ground-up debug + fix)
**Symptom:** the A−/A+ popover size toggle changed nothing on screen.
**Ground-up debug:** 2 Codex (GPT-5.5 xhigh) cold-read the source and web-verified Apple docs; Gemini was hard quota-blocked (HTTP 429, oauth-personal daily cap) so it sits out this round. Both Codex converged, with citations:
- **Root cause:** macOS does not honor Dynamic Type. Apple documents that on macOS `dynamicTypeSize` "cannot be changed by users and does not affect the text size." So `PopoverView.dynamicTypeSize(...)` + `UsageBarView`'s `@ScaledMetric` were silent no-ops; semantic `.caption/.headline` fonts render at fixed macOS sizes regardless. The buttons + @AppStorage worked; only the *rendering* instruction was ignored.
- **Secondary bugs:** (a) default mismatch — PopoverView default step 1 vs App.swift `integer(forKey:)` default 0; (b) menu-bar number didn't update live on toggle (`withObservationTracking` keyed on `model`, not the UserDefault); (c) hard-coded paddings/icons never scaled; (d) panel never resized for bigger content.
**Fix (explicit scaling, NOT scaleEffect — keeps text crisp):** a `Theme.UISize` scale system (`uiSizeStep 0…6` → multiplier table, default 2 ≈ 1.15×) + `Theme.font(role,scale,weight)` real point-size fonts + a `\.uiScale` environment value. Every font and every metric (padding/spacing/icon/bar) in PopoverView/UsageBarView/ProviderCardView now multiplies by scale. App.swift: registers the default + one-time migration off the meaningless pre-fix value, resizes the panel (grow-if-needed + clamp) and restyles the menu-bar number live via `UserDefaults.didChangeNotification` (capped to the menu-bar height). scaleEffect rejected (layer transform softens text at high zoom; doesn't grow hit targets/scroll extent).
**Next:** build + test gates, then ≥2 Opus+Codex hardening rounds before Andrew's visual confirm.

### 2026-06-07 — Hardening round 1 (2 Codex + Opus; Gemini quota-blocked)
Panel grounded in CLAUDE.md + the diff. Findings + resolution:
- **HIGH (Opus, verified vs live UserDefaults):** the planned one-time migration reset the step 6→2 but the saved window frame (574×791) is a separate key restored independently → tiny fonts in a huge half-empty panel on first launch. **Resolution: the migration was DROPPED entirely** (supersedes the migration described in the entry above). `configureUISizeDefaults` now only registers the default + clamps; the user's stored step is HONORED (their saved frame already matches it, and step 6 may be a deliberate low-vision choice — resetting it would stomp an accessibility setting). Simpler and the bug dissolves.
- **HIGH (Codex Integration) / LOW (Opus):** `@objc` defaults observer could run off-main and touch MainActor state. Fixed: `@objc nonisolated uiSizeDefaultsChanged` hops via `Task { @MainActor in self?.handleUISizeDefaultsChanged() }`.
- **MEDIUM (Codex Domain):** progress spinners didn't scale → `Theme.progressSize(for:)` maps scale→ControlSize; **NIT:** bar fill now clamps a stray >100% via `clampedUsed`.
- **MEDIUM (Opus):** "39/39 green" but the scale math lived in the untracked app target with zero tests. Fixed: the pure math (`UISize`, `TextRole`) moved to **NeedMoreTokensKit** (`Sources/NeedMoreTokensKit/UI/UIScale.swift`); `Theme` keeps only the SwiftUI font/spinner glue + the `\.uiScale` env. Added `UIScaleTests` (7 cases) → swift test 32→39.
- Verified by Codex Integration: feedback loop terminates (`lastUISizeStep` set before resize), no retain cycle, autosave storm is a cheap early-return.

### 2026-06-07 — Hardening round 2 (2 Codex + Opus + Gemini retry, all 4)
- **HIGH (Codex Domain, vs Opus):** snap-to-step on every size change discarded a manual drag-resize — and Andrew explicitly asked for resizable/persistent windows. **Resolution (synthesis):** `adjustPanelForStepChange(from:to:)` snaps to the step's natural size only when the window is still at the previous step's default (within 1pt); if the user has manually resized, it preserves that size and only grows to fit. No dead space for the common case, no data loss for the resizer.
- **Gemini (caught what Codex/Opus missed — view code, not scaling):** (1) footer masked errors — once `lastRefresh` was set the error branch was unreachable → now error-first; (2) `RelativeDateTimeFormatter` allocated per render (worsened by scaling re-renders) → shared `nonisolated(unsafe) static let`; (3) `clampedUsed` on the label hid a >100% overage → label now shows true value, bar geometry stays clamped. **Gemini's 4th finding (currency `maximumFractionDigits=0` keeps cents) was REFUTED on-machine** (`$200`/`$19.99`/`$100`) → not applied.
- **MEDIUM (Codex Domain):** sub-1% usage read "0%" beside a visible bar → "<1%" label. **NIT:** plan-name + footer-error get `lineLimit(1)`/truncation so large scale can't break the row.
- **Verified (Opus, on-machine):** `NSFont.preferredFont` base sizes exactly match `TextRole` (26/13/11/12/10/10; caption/caption2 both 10 is correct); anti-pattern sweep clean (no dynamicTypeSize / @ScaledMetric / scaleEffect / Theme.UISize / uiSizeMigratedV2); honor-step-6 and resize-to-step endorsed after mandatory pushback.
- **State:** xcodebuild BUILD SUCCEEDED (0 warnings); swift test 39/39. New files `UIScale.swift` + `UIScaleTests.swift` must be `git add`-ed at commit (untracked).

### 2026-06-07 — Hardening rounds 3 & 4 (convergence; 2 Codex + Opus each)
Two refinements from Round 3, then a final 2-model sign-off in Round 4. Both final reviewers (Codex + Opus, each re-ran the gates on-machine) returned **SHIP / CONVERGED**, no BLOCKER/HIGH/MEDIUM.
- **Round 3 (Codex MEDIUM):** the "did the user manually drag?" test compared only against the *previous* step's default, so a never-dragged user with a **legacy autosaved frame** (e.g. old 360×440 == step-1 default at scale 1.0) was misread as manual and never snapped. **Fix:** `isAppDerivedSize(_:)` now matches the current size against **any** step's natural size within 1pt; `adjustPanelForStepChange(_:to:)` dropped the `from:` param. Opus proved the new check is a strict superset of the old (every old-snap case still snaps, plus the legacy frame). The remaining edge — a manual drag that coincidentally equals some step's default within 1pt gets snapped — is an accepted tradeoff (negligible probability, non-destructive, re-draggable).
- **Round 3 (Codex NIT):** `usedLabel` now shows `>100%` for an overage (was rounding 100.4→"100%"). **Opus/Codex correction to earlier framing:** this branch is **defensive AND reachable**, not unreachable — `EngineMapper` clamps usage at construction, but `RateWindow`'s synthesized `Codable` init reads `usedPercent` off the snapshot **without re-clamping**, so a future/edited snapshot can carry >100. The branch is justified.
- **Round 4 (both, NIT only):** a stale doc comment on `adjustPanelForStepChange` ("previous step") — corrected. Untracked new files — `git add -A` at commit.
- **Deferred to M5/M6 polish (Opus):** replace the 1pt-tolerance app-derived heuristic with an explicit `userDidManuallyResize` flag from the panel's live-resize delegate, eliminating the coincidence-collision class. Not a blocker; tracked here.
- **Convergence:** 4 hardening rounds total (Round 1–2 Codex+Opus, Gemini quota-blocked R1 / contributing R2; Round 3–4 Codex+Opus). Gemini's R2 catches (footer error-masking, per-render formatter, label overage) were real; its currency claim was refuted on-machine. **xcodebuild SUCCEEDED 0/0; swift test 39/39.** The one gate no automated round can cover — a live visual pass at steps 0/2/6 + one A−/A+ toggle — is Andrew's to do before the *feature* (vs the review) is closed.

### 2026-06-09 — Settings pane: subscription price override (M5 start)
The monthly $ was a hardcoded list-price table keyed off the live plan name; codexbar can't tell Claude Max 5× ($100) from 20× ($200), so it guessed $200. **Feature:** a gear in the popover header opens an in-popover Settings pane (`SettingsPaneView`) with a per-provider price field + Claude $100/$200 chips; persists via `@AppStorage("priceOverrideUSD.<provider>")`; re-prices instantly via `AppModel.applyPriceOverrides()` rebuilding from a cached `EngineAdapter.Fetch` (no codexbar re-spawn). Pure store/normalize logic + `subscriptionOverrides` wiring in the Kit. Design approved by Andrew before build.
**Hardening — full panel (2 Codex + Opus + Gemini), then a Codex+Opus verification round. Both verification reviewers: SHIP/converged.** Findings + resolution:
- **HIGH (Gemini + Opus + Codex, unanimous): default-pinning.** The field showed `effective` (the detected default), so focusing it and committing without editing wrote that default as a permanent override (0→200), silently freezing the price. **Fix:** `storePrice` → `PriceOverrides.normalize(_:default:)` (Kit, unit-tested) normalizes a default-equal value back to 0 and drops no-op writes. Opus traced every path (commit-default, real-edit, nil-default, formatter re-emit) — bug is dead.
- **Widget-reload budget (Gemini + Opus):** `applyPriceOverrides` called `reloadAllTimelines()` per edit — WidgetKit budgets reloads. **Fix:** persist only; the periodic refresh reloads. (Pre-existing M6 item: the 120 s refresh loop reloads ~720×/day, over budget once a widget ships.)
- **engineState (Codex wiring):** re-price after a failed refresh stamped the snapshot `.ok`. **Fix:** pass `engineState: engineState`. Tested.
- **Defensive (Codex wiring):** `build()` now ignores a ≤0 override itself, not just the loader. Chip bold keyed on `override == value` (explicit) not `effective`; copy corrected.
- **Refuted (gate/peers contradict):** Gemini's "Swift 6 compiler error" (build clean 0/0; Opus+Codex agree) and "dynamic `@AppStorage` breaks tracking" (3 reviewers confirm it's correct — stable `ForEach` identity).
- **Test-coverage follow-up (Opus):** the load-bearing normalize lived in the untested app target → extracted to `PriceOverrides.normalize` in the Kit + `normalizeTracksDefaultClampsAndKeepsRealEdits`, so the pinning regression can't silently return.
- **Accepted as designed (NIT):** typing the default in the field tracks it (→0) while tapping the $X chip pins it explicitly — different intents, made legible by the chip bold + Default enablement.
- **State:** xcodebuild SUCCEEDED 0/0; **swift test 45/45**. New files `PriceOverrides.swift` + `SettingsPaneView.swift` + `PriceOverridesTests.swift` need `git add -A` at commit. Andrew's live visual pass (gear → set Claude $100/$200 → card updates) is the remaining gate.

### 2026-06-10 — Desktop widget dropped from scope
Andrew cut the widget (M6). The app is menu-bar-only now. The `WidgetSnapshot` / `WidgetSnapshotStore` types **stay** — they are the app's own data model + persistence (the popover renders `WidgetSnapshot.Entry`), not widget-only. Now vestigial without a consumer: the `WidgetCenter.reloadAllTimelines()` calls in the refresh path and the App-Group snapshot save. Left in place for now — harmless, and the door stays open if a widget ever returns; strip on request. The earlier "M6 reload-budget" worry is moot. README + project memory updated.

### 2026-08-23 — Grok weekly usage bar
The Grok card was plan-only because NMT only GETs `grok.com/rest/subscriptions` and hard-coded `windows: []`. The pollable weekly meter is `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with the Grok CLI OIDC bearer. Live on this machine: HTTP 200, `creditUsagePercent: 2.0`, `currentPeriod.type: USAGE_PERIOD_TYPE_WEEKLY`, reset `2026-08-30T18:05:22+00:00`. Does not consume chat quota. `productUsage` is a slice of the same pool (not extra windows). gRPC-web not implemented: REST 200s here. Plan name still comes from subscriptions (6h cache); credits fetch every 120s refresh. `swift test` 151 passed / 1 skipped.
