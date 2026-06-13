import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Phase 5 hardening")
struct Phase5HardeningTests {
    /// A native client that blocks (e.g. on a Keychain access prompt, which happens
    /// before any HTTP timeout) must NOT stall the whole composite — it must time out
    /// to a usageError partial so the composite returns and `.auto` routing can fall
    /// back to codexbar. Other providers must stay live.
    @Test func hungClientTimesOutWhileOthersStayLive() async {
        let liveUsage: @Sendable (Provider) -> ProviderUsage = { p in
            ProviderUsage(provider: p, windows: [], extraWindows: [], accountEmail: nil,
                          planName: nil, creditsRemaining: nil, exactMonthlyCap: nil,
                          statusIndicator: nil, updatedAt: nil)
        }
        let source = NativeProviderDataSource(
            claudeFetch: { _ in
                try? await Task.sleep(nanoseconds: 10_000_000_000) // hang well past the deadline
                return ProviderPartial(provider: .claude, usage: liveUsage(.claude), usageError: nil,
                                       cost: .unavailable(.claude, reason: "late"))
            },
            codexFetch: { _ in
                ProviderPartial(provider: .codex, usage: liveUsage(.codex), usageError: nil,
                                cost: .unavailable(.codex, reason: "x"))
            },
            geminiFetch: { _ in
                ProviderPartial(provider: .gemini, usage: liveUsage(.gemini), usageError: nil,
                                cost: .unavailable(.gemini, reason: "x"))
            },
            timeout: 0.05
        )
        let fetch = await source.fetch(providers: Provider.allCases, cycleAnchorDay: 1, now: Date())
        #expect(fetch.usages[.claude] == nil)
        #expect(fetch.usageErrors[.claude]?.contains("timed out") == true)
        #expect(fetch.usages[.codex] != nil)   // unaffected
        #expect(fetch.usages[.gemini] != nil)  // unaffected
    }
}
