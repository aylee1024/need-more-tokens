import Foundation
import Testing
@testable import NeedMoreTokensKit

/// Loads a committed fixture (sanitized copies of real codexbar 0.32.0 output).
private enum Fixture {
    static func data(_ filename: String) throws -> Data {
        let dot = filename.lastIndex(of: ".") ?? filename.endIndex
        let name = String(filename[..<dot])
        let ext = dot == filename.endIndex ? "" : String(filename[filename.index(after: dot)...])
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "missing fixture \(filename)"
        )
        return try Data(contentsOf: url)
    }
}

@Suite("Engine decode + mapping")
struct EngineDecodeTests {

    // MARK: Framing

    @Test func decodesUsageArrayWithThreeProviders() throws {
        let envelopes = try RawEngineDecoder.usageEnvelopes(from: Fixture.data("usage_all.json"))
        #expect(envelopes.count == 3)
    }

    @Test func decodesNDJSONFallback() throws {
        let envelopes = try RawEngineDecoder.usageEnvelopes(from: Fixture.data("usage_ndjson.txt"))
        #expect(envelopes.count == 2)
    }

    @Test func emptyInputDecodesToEmpty() throws {
        #expect(try RawEngineDecoder.usageEnvelopes(from: Data()).isEmpty)
        #expect(try RawEngineDecoder.usageEnvelopes(from: Data("   \n ".utf8)).isEmpty)
    }

    // MARK: Per-provider window labeling (the correction grounding surfaced)

    @Test func codexWindowsAreFiveHourAndWeekly() throws {
        let mapping = EngineMapper.mapUsage(try RawEngineDecoder.usageEnvelopes(from: Fixture.data("usage_all.json")))
        let codex = try #require(mapping.usages[.codex])
        #expect(codex.windows.map(\.period) == [.fiveHour, .weekly])
        #expect(codex.windows[0].usedPercent == 12)
        #expect(codex.windows[0].remainingPercent == 88)
        #expect(codex.creditsRemaining == 1000)
        #expect(codex.planName == "prolite")
    }

    @Test func geminiWindowsAreAllDaily() throws {
        let mapping = EngineMapper.mapUsage(try RawEngineDecoder.usageEnvelopes(from: Fixture.data("usage_all.json")))
        let gemini = try #require(mapping.usages[.gemini])
        #expect(gemini.windows.count == 3)
        #expect(gemini.windows.allSatisfy { $0.period == .daily })
    }

    @Test func windowLabelsAreModelAndPeriodAware() throws {
        let mapping = EngineMapper.mapUsage(try RawEngineDecoder.usageEnvelopes(from: Fixture.data("usage_all.json")))
        // Gemini: per-model quota buckets, matching the CLI `/model` screen.
        #expect(mapping.usages[.gemini]?.windows.map(\.label) == ["Pro", "Flash", "Flash Lite"])
        // Claude: the duplicate weekly is the model-specific weekly cap (default
        // Sonnet from codexbar; the direct API overrides with the active model).
        #expect(mapping.usages[.claude]?.windows.map(\.label) == ["5-hour", "Weekly", "Weekly · Sonnet"])
        // Codex: labeled purely by period.
        #expect(mapping.usages[.codex]?.windows.map(\.label) == ["5-hour", "Weekly"])
    }

    @Test func claudeHasExactMonthlyCapAndTwoWeeklyWindows() throws {
        let mapping = EngineMapper.mapUsage(try RawEngineDecoder.usageEnvelopes(from: Fixture.data("usage_all.json")))
        let claude = try #require(mapping.usages[.claude])
        #expect(claude.windows.map(\.period) == [.fiveHour, .weekly, .weekly])
        let cap = try #require(claude.exactMonthlyCap)
        #expect(cap.limit == 40)
        #expect(cap.used == 0)
        #expect(cap.periodLabel == "Monthly cap")
        #expect(claude.planName == "Claude Max")
    }

    @Test func tightestWindowPicksLowestRemaining() throws {
        let mapping = EngineMapper.mapUsage(try RawEngineDecoder.usageEnvelopes(from: Fixture.data("usage_all.json")))
        // Claude: 5h used 13 (87 left), weekly used 40 (60 left), weekly used 1 (99 left) → tightest is the 40%-used weekly.
        let claude = try #require(mapping.usages[.claude])
        #expect(claude.tightestWindow?.usedPercent == 40)
    }

    // MARK: Cost — Gemini gap + cycle math + estimated flag

    @Test func costMapsClaudeAndCodexButNotGemini() throws {
        let cost = EngineMapper.mapCost(
            try RawEngineDecoder.costEnvelopes(from: Fixture.data("cost_all.json")),
            cycleStartDayKey: "2026-06-01"
        )
        #expect(Set(cost.keys) == [.codex, .claude])
        #expect(cost[.gemini] == nil) // engine returns an error / "cli" entry; caller fills unavailable
    }

    @Test func cycleCostSumsFromAnchorOnly() throws {
        let cost = EngineMapper.mapCost(
            try RawEngineDecoder.costEnvelopes(from: Fixture.data("cost_all.json")),
            cycleStartDayKey: "2026-06-01"
        )
        let codex = try #require(cost[.codex])
        #expect(codex.cycleCostUSD == 54.0)        // 20 (06-01) + 34 (06-06); excludes 05-31's 10
        #expect(codex.last30DaysCostUSD == 64.0)
        #expect(codex.isEstimated == true)         // source "local"
        let claude = try #require(cost[.claude])
        #expect(claude.cycleCostUSD == 108.0)
    }

    @Test func geminiUnavailableHelperIsHonest() {
        let cost = ProviderCost.unavailable(.gemini, reason: "Not computed for Gemini by the engine")
        #expect(cost.isAvailable == false)
        #expect(cost.isEstimated == false)
        #expect(cost.cycleCostUSD == nil)
        #expect(cost.unavailableReason != nil)
    }

    // MARK: Tolerance

    @Test func toleratesMissingFieldsAndUnknownProviders() throws {
        let mapping = EngineMapper.mapUsage(try RawEngineDecoder.usageEnvelopes(from: Fixture.data("usage_tolerance.json")))
        #expect(Set(mapping.usages.keys) == [.claude, .codex]) // unknown "grok-future" dropped
        #expect(mapping.usages[.claude]?.windows.count == 1)    // primary 5h
        // codex primary lacked windowMinutes → dropped; secondary weekly kept.
        #expect(mapping.usages[.codex]?.windows.count == 1)
        #expect(mapping.usages[.codex]?.windows.first?.period == .weekly)
    }

    @Test func errorEnvelopeBecomesProviderError() throws {
        let json = Data(#"[{"provider":"claude","error":{"code":1,"message":"boom"}}]"#.utf8)
        let mapping = EngineMapper.mapUsage(try RawEngineDecoder.usageEnvelopes(from: json))
        #expect(mapping.usages[.claude] == nil)
        #expect(mapping.errors[.claude] == "boom")
    }

    // MARK: Units

    @Test func windowPeriodLabels() {
        #expect(RateWindow.Period(windowMinutes: 300).shortLabel == "5-hour")
        #expect(RateWindow.Period(windowMinutes: 1440).shortLabel == "Daily")
        #expect(RateWindow.Period(windowMinutes: 10080).shortLabel == "Weekly")
        #expect(RateWindow.Period(windowMinutes: 180).shortLabel == "3h")
        #expect(RateWindow.Period(windowMinutes: 2880).shortLabel == "2d")
        #expect(RateWindow.Period(windowMinutes: 90).shortLabel == "90m")
    }

    @Test func sanitizeMoneyRejectsBadValues() {
        #expect(EngineMapper.sanitizeMoney(.nan) == 0)
        #expect(EngineMapper.sanitizeMoney(.infinity) == 0)
        #expect(EngineMapper.sanitizeMoney(-5) == 0)
        #expect(EngineMapper.sanitizeMoney(nil) == 0)
        #expect(EngineMapper.sanitizeMoney(3.5) == 3.5)
    }

    @Test func providerNormalizationAliases() {
        #expect(Provider.normalized("anthropic") == .claude)
        #expect(Provider.normalized("OpenAI") == .codex)
        #expect(Provider.normalized("google") == .gemini)
        #expect(Provider.normalized("cli") == nil)
        #expect(Provider.normalized(nil) == nil)
    }

    @Test func firstOfMonthDayKeyIsDeterministic() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        #expect(EngineMapper.firstOfMonthDayKey(for: date, calendar: calendar) == "2026-06-01")
    }
}
