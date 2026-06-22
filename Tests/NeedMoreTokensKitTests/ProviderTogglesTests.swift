import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("ProviderToggles")
struct ProviderTogglesTests {
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "nmt-toggles-\(UUID().uuidString)")!
        return d
    }

    @Test func keysAreStableAndProviderScoped() {
        #expect(ProviderToggles.key(for: .claude) == "providerEnabled.claude")
        #expect(ProviderToggles.key(for: .grok) == "providerEnabled.grok")
        // Distinct per provider.
        let keys = Provider.allCases.map { ProviderToggles.key(for: $0) }
        #expect(Set(keys).count == Provider.allCases.count)
    }

    @Test func defaultsToEnabledWhenAbsent() {
        let d = freshDefaults()
        // No keys written → every provider is ON (opt-out, not opt-in).
        #expect(ProviderToggles.loadEnabled(from: d) == Provider.allCases)
        for p in Provider.allCases { #expect(ProviderToggles.isEnabled(p, in: d)) }
    }

    @Test func disablingExcludesFromEnabledButKeepsOrder() {
        let d = freshDefaults()
        ProviderToggles.setEnabled(false, for: .gemini, in: d)
        let enabled = ProviderToggles.loadEnabled(from: d)
        #expect(!enabled.contains(.gemini))
        #expect(enabled == Provider.allCases.filter { $0 != .gemini })  // order preserved
        #expect(ProviderToggles.isEnabled(.gemini, in: d) == false)
        #expect(ProviderToggles.isEnabled(.claude, in: d) == true)
    }

    @Test func reEnablingRestores() {
        let d = freshDefaults()
        ProviderToggles.setEnabled(false, for: .grok, in: d)
        #expect(!ProviderToggles.loadEnabled(from: d).contains(.grok))
        ProviderToggles.setEnabled(true, for: .grok, in: d)
        #expect(ProviderToggles.loadEnabled(from: d).contains(.grok))
    }
}
