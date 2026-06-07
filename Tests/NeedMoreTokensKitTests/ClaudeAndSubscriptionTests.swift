import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Subscriptions, billing anchor, snapshot decode-tolerance")
struct SubscriptionsAndSnapshotTests {

    @Test func subscriptionDefaultsMatchKnownPlans() {
        #expect(Subscriptions.defaultMonthlyUSD(for: .claude, planName: "Claude Max") == 200)
        #expect(Subscriptions.defaultMonthlyUSD(for: .codex, planName: "Pro 5x") == 100)
        #expect(Subscriptions.defaultMonthlyUSD(for: .codex, planName: "Plus") == 20)
        #expect(Subscriptions.defaultMonthlyUSD(for: .gemini, planName: "Paid") == 19.99)
        #expect(Subscriptions.defaultMonthlyUSD(for: .gemini, planName: "Ultra") == 99.99)
    }

    @Test func unknownPlansDoNotShowAPaidPrice() {
        // A missing/failed plan read must not render a paid subscription line.
        #expect(Subscriptions.defaultMonthlyUSD(for: .gemini, planName: nil) == nil)
        #expect(Subscriptions.defaultMonthlyUSD(for: .claude, planName: nil) == nil)
        #expect(Subscriptions.defaultMonthlyUSD(for: .codex, planName: "") == nil)
    }

    @Test func billingAnchorBeforeTodayUsesThisMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let june7 = cal.date(from: DateComponents(year: 2026, month: 6, day: 7))!
        #expect(EngineMapper.firstOfMonthDayKey(for: june7, anchorDay: 1, calendar: cal) == "2026-06-01")
    }

    @Test func billingAnchorAfterTodayRollsBackAMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let june7 = cal.date(from: DateComponents(year: 2026, month: 6, day: 7))!
        // Anchor day 15 hasn't arrived yet on June 7 → cycle started May 15, not a
        // future June 15 (which would sum zero current-cycle cost).
        #expect(EngineMapper.firstOfMonthDayKey(for: june7, anchorDay: 15, calendar: cal) == "2026-05-15")
    }

    @Test func billingAnchorClampsInvalidDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let feb10 = cal.date(from: DateComponents(year: 2026, month: 2, day: 10))!
        // Day 31 clamps to 28 (every month has it); on Feb 10, day 28 hasn't arrived → Jan 28.
        #expect(EngineMapper.firstOfMonthDayKey(for: feb10, anchorDay: 31, calendar: cal) == "2026-01-28")
    }

    @Test func snapshotEntryDecodesToleratingMissingAddedFields() throws {
        // Regression for the latent widget bug: an Entry written by an older build
        // (no extraWindows / monthlyPriceUSD / errorMessage keys) must still decode.
        let json = Data("""
        {
          "provider": "codex",
          "windows": [],
          "cost": { "isAvailable": false, "isEstimated": false, "currencyCode": "USD" },
          "state": "live"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(WidgetSnapshot.Entry.self, from: json)
        #expect(entry.provider == .codex)
        #expect(entry.extraWindows.isEmpty)
        #expect(entry.monthlyPriceUSD == nil)
        #expect(entry.errorMessage == nil)
        #expect(entry.state == .live)
    }
}
