import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("RoutingProviderDataSource")
struct RoutingProviderDataSourceTests {
    @Test func routesEachProviderByPolicy() async throws {
        let native = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers, source: "native", generatedAt: now)
        }
        let codexbar = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers, source: "codexbar", generatedAt: now)
        }
        let router = RoutingProviderDataSource(
            native: native,
            codexbar: codexbar,
            policy: { provider in
                switch provider {
                case .claude: .native
                case .codex: .codexbar
                case .gemini: .auto
                }
            },
            fallbackOnError: true
        )

        let fetch = await router.fetch(providers: [.claude, .codex, .gemini], cycleAnchorDay: 17, now: dataSourceTestNow)

        #expect(await native.calls() == [
            RecordedDataSourceCall(providers: [.claude, .gemini], cycleAnchorDay: 17, now: dataSourceTestNow),
        ])
        #expect(await codexbar.calls() == [
            RecordedDataSourceCall(providers: [.codex], cycleAnchorDay: 17, now: dataSourceTestNow),
        ])
        #expect(fetch.usages[.claude]?.planName == "native")
        #expect(fetch.usages[.gemini]?.planName == "native")
        #expect(fetch.usages[.codex]?.planName == "codexbar")
    }

    @Test func codexbarRoutedProvidersGoToCodexbarSource() async throws {
        let native = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers, source: "native", generatedAt: now)
        }
        let codexbar = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers, source: "codexbar", generatedAt: now)
        }
        let router = RoutingProviderDataSource(
            native: native,
            codexbar: codexbar,
            policy: { _ in .codexbar },
            fallbackOnError: true
        )

        let fetch = await router.fetch(providers: [.codex, .gemini], cycleAnchorDay: 1, now: dataSourceTestNow)

        #expect(await native.calls().isEmpty)
        #expect(await codexbar.calls() == [
            RecordedDataSourceCall(providers: [.codex, .gemini], cycleAnchorDay: 1, now: dataSourceTestNow),
        ])
        #expect(fetch.usages[.codex]?.planName == "codexbar")
        #expect(fetch.usages[.gemini]?.planName == "codexbar")
    }

    @Test func autoNativeErrorFallsBackToCodexbarAndUsesCodexbarValue() async throws {
        let native = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers.filter { $0 != .codex },
                          errors: [.codex: "native codex failed"],
                          source: "native",
                          generatedAt: now)
        }
        let codexbar = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers, source: "codexbar", generatedAt: now)
        }
        let router = RoutingProviderDataSource(
            native: native,
            codexbar: codexbar,
            policy: { _ in .auto },
            fallbackOnError: true
        )

        let fetch = await router.fetch(providers: [.codex], cycleAnchorDay: 1, now: dataSourceTestNow)

        #expect(fetch.usages[.codex]?.planName == "codexbar")
        #expect(fetch.usageErrors[.codex] == nil)
        #expect(fetch.costs[.codex]?.cycleCostUSD == 12)
        #expect(await native.calls().map(\.providers) == [[.codex]])
        #expect(await codexbar.calls().map(\.providers) == [[.codex]])
    }

    @Test func fallbackDisabledKeepsNativeError() async throws {
        let native = RecordingProviderDataSource { _, _, now in
            providerFetch(successes: [], errors: [.codex: "native codex failed"], source: "native", generatedAt: now)
        }
        let codexbar = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers, source: "codexbar", generatedAt: now)
        }
        let router = RoutingProviderDataSource(
            native: native,
            codexbar: codexbar,
            policy: { _ in .auto },
            fallbackOnError: false
        )

        let fetch = await router.fetch(providers: [.codex], cycleAnchorDay: 1, now: dataSourceTestNow)

        #expect(fetch.usages[.codex] == nil)
        #expect(fetch.usageErrors[.codex] == "native codex failed")
        #expect(await codexbar.calls().isEmpty)
    }

    @Test func codexbarThrowBecomesProviderErrorsWhileNativeProvidersStayLive() async throws {
        let native = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers, source: "native", generatedAt: now)
        }
        let codexbar = RecordingProviderDataSource { _, _, _ in
            throw EngineError.binaryMissing
        }
        let router = RoutingProviderDataSource(
            native: native,
            codexbar: codexbar,
            policy: { provider in provider == .codex ? .codexbar : .native },
            fallbackOnError: false
        )

        let fetch = await router.fetch(providers: [.claude, .codex], cycleAnchorDay: 1, now: dataSourceTestNow)

        #expect(fetch.usages[.claude]?.planName == "native")
        #expect(fetch.usages[.codex] == nil)
        #expect(fetch.usageErrors[.codex] == "codexbar not found")
        #expect(fetch.costs[.codex]?.isAvailable == false)
        #expect(await native.calls().map(\.providers) == [[.claude]])
        #expect(await codexbar.calls().map(\.providers) == [[.codex]])
    }

    @Test func mergesUsagesErrorsAndCostsFromBothSources() async throws {
        let native = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers.filter { $0 == .claude },
                          errors: providers.contains(.gemini) ? [.gemini: "gemini native failed"] : [:],
                          source: "native",
                          generatedAt: now)
        }
        let codexbar = RecordingProviderDataSource { providers, _, now in
            providerFetch(successes: providers, source: "codexbar", generatedAt: now)
        }
        let router = RoutingProviderDataSource(
            native: native,
            codexbar: codexbar,
            policy: { provider in provider == .codex ? .codexbar : .native },
            fallbackOnError: false
        )

        let fetch = await router.fetch(providers: [.claude, .codex, .gemini], cycleAnchorDay: 1, now: dataSourceTestNow)

        #expect(fetch.generatedAt == dataSourceTestNow)
        #expect(Set(fetch.usages.keys) == Set([Provider.claude, .codex]))
        #expect(fetch.usageErrors == [.gemini: "gemini native failed"])
        #expect(Set(fetch.costs.keys) == Set([Provider.claude, .codex, .gemini]))
        #expect(fetch.usages[.claude]?.planName == "native")
        #expect(fetch.usages[.codex]?.planName == "codexbar")
        #expect(fetch.costs[.gemini]?.isAvailable == false)
    }
}
