import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Subscriptions and snapshot decode-tolerance")
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

    @Test func snapshotEntryRoundTripsResetCount() throws {
        let entry = WidgetSnapshot.Entry(
            provider: .codex,
            planName: "Pro 5x",
            accountEmail: "andrew@example.com",
            windows: [],
            cost: WidgetSnapshot.CostSummary(
                isAvailable: false,
                isEstimated: false,
                currencyCode: "USD",
                cycleCostUSD: nil,
                lifetimeCostUSD: nil,
                unavailableReason: nil
            ),
            creditsRemaining: 1000,
            exactMonthlyCap: nil,
            state: .live,
            updatedAt: nil,
            resetCount: 2
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.Entry.self, from: data)

        #expect(decoded == entry)
        #expect(decoded.resetCount == 2)
    }

    @Test func snapshotEntryMissingResetCountDecodesAsNil() throws {
        let json = Data("""
        {
          "provider": "codex",
          "windows": [],
          "cost": { "isAvailable": false, "isEstimated": false, "currencyCode": "USD" },
          "state": "live"
        }
        """.utf8)

        let entry = try JSONDecoder().decode(WidgetSnapshot.Entry.self, from: json)

        #expect(entry.resetCount == nil)
    }
}
