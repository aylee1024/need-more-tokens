import Foundation
import Testing
@testable import NeedMoreTokensKit

/// A minimal provider-source conformer — the shape native clients and any mock
/// will take. It implements ONLY the protocol requirement; the
/// convenience `fetch()` comes from the extension. If the extension ever re-declared
/// the full-signature method with default args again, this would recurse forever
/// instead of returning — so this test guards the seam against that regression.
private struct StubDataSource: ProviderDataSource {
    let stamp: Date
    func fetch(providers: [Provider], cycleAnchorDay: Int, now: Date) async throws -> ProviderFetch {
        ProviderFetch(usages: [:], usageErrors: [:], costs: [:], generatedAt: stamp)
    }
}

@Suite("ProviderDataSource seam")
struct DataSourceSeamTests {
    @Test func convenienceFetchForwardsToRequirementWithoutRecursing() async throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source: ProviderDataSource = StubDataSource(stamp: stamp)
        let fetch = try await source.fetch()
        #expect(fetch.generatedAt == stamp)
        #expect(fetch.usages.isEmpty)
    }

    @Test func providerFetchPublicInitIsUsableAcrossModuleBoundary() {
        let f = ProviderFetch(usages: [:], usageErrors: [.codex: "x"], costs: [:],
                              generatedAt: Date(timeIntervalSince1970: 0))
        #expect(f.usage(for: .codex) == nil)
        #expect(f.usageErrors[.codex] == "x")
    }
}
