import Foundation
@testable import NeedMoreTokensKit

let dataSourceTestNow = Date(timeIntervalSince1970: 1_700_000_000)

struct RecordedDataSourceCall: Sendable, Equatable {
    let providers: [Provider]
    let cycleAnchorDay: Int
    let now: Date
}

actor RecordingProviderDataSource: ProviderDataSource {
    typealias Handler = @Sendable ([Provider], Int, Date) throws -> ProviderFetch

    private let handler: Handler
    private var recordedCalls: [RecordedDataSourceCall] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func fetch(providers: [Provider], cycleAnchorDay: Int, now: Date) async throws -> ProviderFetch {
        recordedCalls.append(RecordedDataSourceCall(providers: providers, cycleAnchorDay: cycleAnchorDay, now: now))
        return try handler(providers, cycleAnchorDay, now)
    }

    func calls() -> [RecordedDataSourceCall] {
        recordedCalls
    }
}

func testUsage(_ provider: Provider, source: String, now: Date = dataSourceTestNow) -> ProviderUsage {
    ProviderUsage(
        provider: provider,
        windows: [
            RateWindow(
                label: "5-hour",
                period: .fiveHour,
                windowMinutes: 300,
                usedPercent: usedPercent(for: provider),
                resetsAt: nil,
                resetDescription: nil
            ),
        ],
        accountEmail: nil,
        planName: source,
        creditsRemaining: nil,
        exactMonthlyCap: nil,
        statusIndicator: nil,
        updatedAt: now
    )
}

func testCost(_ provider: Provider, source: String, now: Date = dataSourceTestNow) -> ProviderCost {
    ProviderCost(
        provider: provider,
        isAvailable: true,
        unavailableReason: nil,
        isEstimated: false,
        currencyCode: "USD",
        sessionCostUSD: nil,
        last30DaysCostUSD: nil,
        cycleCostUSD: costAmount(for: provider, source: source),
        lifetimeCostUSD: nil,
        daily: [],
        updatedAt: now
    )
}

func successfulPartial(_ provider: Provider, source: String, now: Date = dataSourceTestNow) -> ProviderPartial {
    ProviderPartial(
        provider: provider,
        usage: testUsage(provider, source: source, now: now),
        usageError: nil,
        cost: testCost(provider, source: source, now: now)
    )
}

func failingPartial(_ provider: Provider, message: String) -> ProviderPartial {
    ProviderPartial(
        provider: provider,
        usage: nil,
        usageError: message,
        cost: .unavailable(provider, reason: message)
    )
}

func providerFetch(successes: [Provider],
                   errors: [Provider: String] = [:],
                   source: String,
                   generatedAt: Date) -> ProviderFetch {
    var usages: [Provider: ProviderUsage] = [:]
    var costs: [Provider: ProviderCost] = [:]
    for provider in successes {
        usages[provider] = testUsage(provider, source: source, now: generatedAt)
        costs[provider] = testCost(provider, source: source, now: generatedAt)
    }
    for (provider, message) in errors {
        costs[provider] = .unavailable(provider, reason: message)
    }
    return ProviderFetch(usages: usages, usageErrors: errors, costs: costs, generatedAt: generatedAt)
}

private func usedPercent(for provider: Provider) -> Double {
    switch provider {
    case .claude: 10
    case .codex: 20
    case .gemini: 30
    }
}

private func costAmount(for provider: Provider, source _: String) -> Double {
    switch provider {
    case .claude: 1
    case .codex: 2
    case .gemini: 3
    }
}
