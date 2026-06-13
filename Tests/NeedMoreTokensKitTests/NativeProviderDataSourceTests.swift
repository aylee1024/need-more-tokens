import Foundation
import Testing
@testable import NeedMoreTokensKit

private actor NativeClientRecorder {
    private let partials: [Provider: ProviderPartial]
    private var calls: [Provider] = []

    init(partials: [Provider: ProviderPartial]) {
        self.partials = partials
    }

    func fetch(_ provider: Provider, now: Date) -> ProviderPartial {
        calls.append(provider)
        return partials[provider] ?? failingPartial(provider, message: "missing test partial")
    }

    func calledProviders() -> [Provider] {
        calls
    }
}

@Suite("NativeProviderDataSource")
struct NativeProviderDataSourceTests {
    @Test func independentPerProviderFailureKeepsOtherProvidersLive() async throws {
        let recorder = NativeClientRecorder(partials: [
            .claude: successfulPartial(.claude, source: "native"),
            .codex: failingPartial(.codex, message: "codex native failed"),
            .gemini: successfulPartial(.gemini, source: "native"),
        ])
        let source = nativeSource(recorder)

        let fetch = await source.fetch(providers: Provider.allCases, cycleAnchorDay: 1, now: dataSourceTestNow)

        #expect(Set(fetch.usages.keys) == Set([Provider.claude, .gemini]))
        #expect(fetch.usageErrors == [.codex: "codex native failed"])
        #expect(Set(fetch.costs.keys) == Set(Provider.allCases))
        #expect(fetch.generatedAt == dataSourceTestNow)
    }

    @Test func allRequestedProvidersArePresentWhenClientsSucceed() async throws {
        let recorder = NativeClientRecorder(partials: [
            .claude: successfulPartial(.claude, source: "native"),
            .codex: successfulPartial(.codex, source: "native"),
            .gemini: successfulPartial(.gemini, source: "native"),
        ])
        let source = nativeSource(recorder)

        let fetch = await source.fetch(providers: Provider.allCases, cycleAnchorDay: 1, now: dataSourceTestNow)

        #expect(Set(fetch.usages.keys) == Set(Provider.allCases))
        #expect(fetch.usageErrors.isEmpty)
        #expect(Set(fetch.costs.keys) == Set(Provider.allCases))
    }

    @Test func onlyRequestedSubsetIsFetched() async throws {
        let recorder = NativeClientRecorder(partials: [
            .claude: successfulPartial(.claude, source: "native"),
            .codex: successfulPartial(.codex, source: "native"),
            .gemini: successfulPartial(.gemini, source: "native"),
        ])
        let source = nativeSource(recorder)

        let fetch = await source.fetch(providers: [.gemini], cycleAnchorDay: 1, now: dataSourceTestNow)

        #expect(Set(await recorder.calledProviders()) == Set([Provider.gemini]))
        #expect(Set(fetch.usages.keys) == Set([Provider.gemini]))
        #expect(Set(fetch.costs.keys) == Set([Provider.gemini]))
        #expect(fetch.usageErrors.isEmpty)
    }

    private func nativeSource(_ recorder: NativeClientRecorder) -> NativeProviderDataSource {
        NativeProviderDataSource(
            claudeFetch: { now in await recorder.fetch(.claude, now: now) },
            codexFetch: { now in await recorder.fetch(.codex, now: now) },
            geminiFetch: { now in await recorder.fetch(.gemini, now: now) }
        )
    }
}
