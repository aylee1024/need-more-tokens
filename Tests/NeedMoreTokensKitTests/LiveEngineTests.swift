import Foundation
import Testing
@testable import NeedMoreTokensKit

/// Opt-in smoke test that runs the REAL codexbar engine end-to-end. Skipped unless
/// `NMT_LIVE=1` (so it never runs in CI without the binary + signed-in providers):
///
///   NMT_LIVE=1 swift test --filter LiveEngineTests
@Suite("Live engine (opt-in)")
struct LiveEngineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NMT_LIVE"] == "1"))
    func fetchesRealUsageAndCostAndBuildsSnapshot() async throws {
        let fetch = try await EngineAdapter().fetch()
        let snapshot = WidgetSnapshot.build(from: fetch, enabledProviders: Provider.allCases)

        for entry in snapshot.entries {
            let windows = entry.windows
                .map { "\($0.period.shortLabel) \(Int($0.usedPercent))% used" }
                .joined(separator: ", ")
            let cost = entry.cost.isAvailable
                ? (entry.cost.cycleCostUSD.map { String(format: "$%.2f cycle", $0) } ?? "—")
                    + (entry.cost.isEstimated ? " (est.)" : " (exact)")
                : "n/a (\(entry.cost.unavailableReason ?? "unavailable"))"
            print("• \(entry.provider.displayName) [\(entry.planName ?? "?")] — \(windows.isEmpty ? "no windows" : windows) | cost: \(cost)")
        }

        #expect(snapshot.entries.count == 3)
        #expect(fetch.usages.values.contains { !$0.windows.isEmpty }) // at least one provider has windows
    }
}
