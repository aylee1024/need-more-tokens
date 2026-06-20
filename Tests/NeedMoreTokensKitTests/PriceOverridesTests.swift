import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Subscription price overrides")
struct PriceOverridesTests {

    @Test func keysAreStableAndProviderScoped() {
        #expect(PriceOverrides.key(for: .claude) == "priceOverrideUSD.claude")
        #expect(PriceOverrides.key(for: .codex) == "priceOverrideUSD.codex")
        #expect(PriceOverrides.key(for: .gemini) == "priceOverrideUSD.gemini")
    }

    @Test func loadKeepsNonzeroOverridesAndIgnoresZeroOrAbsent() {
        let suite = "nmt.tests.priceoverrides.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(100, forKey: PriceOverrides.key(for: .claude))   // set
        defaults.set(0, forKey: PriceOverrides.key(for: .codex))      // zero = "use default"
        // gemini intentionally absent

        let loaded = PriceOverrides.load(from: defaults)
        #expect(loaded[.claude] == 100)
        #expect(loaded[.codex] == nil)
        #expect(loaded[.gemini] == nil)
    }

    @Test func overrideBeatsDetectedDefaultInBuild() {
        let usage = ProviderUsage(
            provider: .claude, windows: [], accountEmail: nil, planName: "Claude Max",
            creditsRemaining: nil, exactMonthlyCap: nil, statusIndicator: nil, updatedAt: nil
        )
        let fetch = ProviderFetch(
            usages: [.claude: usage], usageErrors: [:], costs: [:], generatedAt: Date()
        )

        // No override → the detected list price (Claude Max defaults to $200).
        let defaulted = WidgetSnapshot.build(from: fetch, enabledProviders: [.claude])
        #expect(defaulted.entries.first?.monthlyPriceUSD == 200)

        // Override → the user's price wins.
        let overridden = WidgetSnapshot.build(
            from: fetch, enabledProviders: [.claude], subscriptionOverrides: [.claude: 100]
        )
        #expect(overridden.entries.first?.monthlyPriceUSD == 100)
    }

    @Test func buildIgnoresNonPositiveOverride() {
        let usage = ProviderUsage(
            provider: .claude, windows: [], accountEmail: nil, planName: "Claude Max",
            creditsRemaining: nil, exactMonthlyCap: nil, statusIndicator: nil, updatedAt: nil
        )
        let fetch = ProviderFetch(
            usages: [.claude: usage], usageErrors: [:], costs: [:], generatedAt: Date()
        )
        // A 0/negative override means "no override" — fall back to the detected default,
        // never price at $0.
        let zero = WidgetSnapshot.build(
            from: fetch, enabledProviders: [.claude], subscriptionOverrides: [.claude: 0]
        )
        #expect(zero.entries.first?.monthlyPriceUSD == 200)
        let negative = WidgetSnapshot.build(
            from: fetch, enabledProviders: [.claude], subscriptionOverrides: [.claude: -10]
        )
        #expect(negative.entries.first?.monthlyPriceUSD == 200)
    }

    @Test func normalizeTracksDefaultClampsAndKeepsRealEdits() {
        // Committing the shown default tracks it (→ 0), never pins it — the regression guard
        // for the just-fixed "focus + commit pins the default" bug.
        #expect(PriceOverrides.normalize(200, default: 200) == 0)
        #expect(PriceOverrides.normalize(19.99, default: 19.99) == 0)   // cent-level default
        #expect(PriceOverrides.normalize(150, default: 200) == 150)     // a real edit persists
        #expect(PriceOverrides.normalize(19.99, default: 200) == 19.99)
        #expect(PriceOverrides.normalize(-5, default: nil) == 0)        // clamps negative
        #expect(PriceOverrides.normalize(0, default: nil) == 0)
        #expect(PriceOverrides.normalize(100, default: nil) == 100)     // nil default keeps a real value
    }

    @Test func buildPreservesEngineState() {
        let fetch = ProviderFetch(usages: [:], usageErrors: [:], costs: [:], generatedAt: Date())
        #expect(WidgetSnapshot.build(from: fetch, enabledProviders: []).engineState == .ok)
        #expect(WidgetSnapshot.build(from: fetch, enabledProviders: [], engineState: .error)
            .engineState == .error)
    }
}
