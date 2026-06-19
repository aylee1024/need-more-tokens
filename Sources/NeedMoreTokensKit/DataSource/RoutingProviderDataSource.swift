import Foundation

public struct RoutingProviderDataSource: ProviderDataSource {
    private enum Source: Sendable, Equatable {
        case native
        case codexbar

        var fallback: Source {
            switch self {
            case .native: .codexbar
            case .codexbar: .native
            }
        }
    }

    private struct SourceResult: Sendable {
        let source: Source
        let providers: [Provider]
        let fetch: ProviderFetch
    }

    private let native: ProviderDataSource
    private let codexbar: ProviderDataSource
    private let policy: @Sendable (Provider) -> DataSourcePolicy
    private let fallbackOnError: Bool

    public init(native: ProviderDataSource,
                codexbar: ProviderDataSource,
                policy: @escaping @Sendable (Provider) -> DataSourcePolicy,
                fallbackOnError: Bool) {
        self.native = native
        self.codexbar = codexbar
        self.policy = policy
        self.fallbackOnError = fallbackOnError
    }

    public func fetch(providers: [Provider],
                      cycleAnchorDay: Int,
                      now: Date) async -> ProviderFetch {
        var initialSourceByProvider: [Provider: Source] = [:]
        var nativeProviders: [Provider] = []
        var codexbarProviders: [Provider] = []

        for provider in providers {
            switch policy(provider) {
            case .auto, .native:
                initialSourceByProvider[provider] = .native
                nativeProviders.append(provider)
            case .codexbar:
                initialSourceByProvider[provider] = .codexbar
                codexbarProviders.append(provider)
            }
        }

        let initialResults = await fetchSources(
            nativeProviders: nativeProviders,
            codexbarProviders: codexbarProviders,
            cycleAnchorDay: cycleAnchorDay,
            now: now
        )

        var merged = ProviderFetch(usages: [:], usageErrors: [:], costs: [:], generatedAt: now)
        for result in initialResults {
            merge(result.fetch, into: &merged, allowing: Set(result.providers))
        }

        guard fallbackOnError else { return merged }

        var nativeFallbackProviders: [Provider] = []
        var codexbarFallbackProviders: [Provider] = []
        for provider in providers where merged.usageErrors[provider] != nil {
            switch initialSourceByProvider[provider]?.fallback {
            case .native:
                nativeFallbackProviders.append(provider)
            case .codexbar:
                codexbarFallbackProviders.append(provider)
            case nil:
                break
            }
        }

        let fallbackResults = await fetchSources(
            nativeProviders: nativeFallbackProviders,
            codexbarProviders: codexbarFallbackProviders,
            cycleAnchorDay: cycleAnchorDay,
            now: now
        )
        for result in fallbackResults {
            applySuccessfulFallback(result.fetch, into: &merged, allowing: Set(result.providers))
        }

        return merged
    }

    private func fetchSources(nativeProviders: [Provider],
                              codexbarProviders: [Provider],
                              cycleAnchorDay: Int,
                              now: Date) async -> [SourceResult] {
        await withTaskGroup(of: SourceResult.self) { group in
            if !nativeProviders.isEmpty {
                group.addTask {
                    await fetch(.native, providers: nativeProviders, cycleAnchorDay: cycleAnchorDay, now: now)
                }
            }
            if !codexbarProviders.isEmpty {
                group.addTask {
                    await fetch(.codexbar, providers: codexbarProviders, cycleAnchorDay: cycleAnchorDay, now: now)
                }
            }

            var results: [SourceResult] = []
            while let result = await group.next() {
                results.append(result)
            }
            return results
        }
    }

    private func fetch(_ source: Source,
                       providers: [Provider],
                       cycleAnchorDay: Int,
                       now: Date) async -> SourceResult {
        do {
            let dataSource = dataSource(for: source)
            let fetch = try await dataSource.fetch(providers: providers, cycleAnchorDay: cycleAnchorDay, now: now)
            return SourceResult(source: source, providers: providers, fetch: fetch)
        } catch {
            return SourceResult(
                source: source,
                providers: providers,
                fetch: failedFetch(source: source, providers: providers, error: error, now: now)
            )
        }
    }

    private func dataSource(for source: Source) -> ProviderDataSource {
        switch source {
        case .native: native
        case .codexbar: codexbar
        }
    }

    private func merge(_ fetch: ProviderFetch, into merged: inout ProviderFetch, allowing providers: Set<Provider>) {
        for (provider, usage) in fetch.usages where providers.contains(provider) {
            merged.usages[provider] = usage
        }
        for (provider, error) in fetch.usageErrors where providers.contains(provider) {
            merged.usageErrors[provider] = error
        }
        for (provider, cost) in fetch.costs where providers.contains(provider) {
            merged.costs[provider] = cost
        }
    }

    private func applySuccessfulFallback(_ fetch: ProviderFetch,
                                         into merged: inout ProviderFetch,
                                         allowing providers: Set<Provider>) {
        for provider in providers {
            guard let usage = fetch.usages[provider] else { continue }
            merged.usages[provider] = usage
            merged.usageErrors[provider] = nil
            if let cost = fetch.costs[provider] {
                merged.costs[provider] = cost
            }
        }
    }

    private func failedFetch(source: Source,
                             providers: [Provider],
                             error: Error,
                             now: Date) -> ProviderFetch {
        // uniquingKeysWith (not uniqueKeysWithValues) so a duplicate Provider in
        // the input can never trap with "Duplicate keys found in Dictionary".
        let errors = Dictionary(providers.map { provider in
            (provider, sourceErrorMessage(source: source, provider: provider, error: error))
        }, uniquingKeysWith: { first, _ in first })
        let costs = Dictionary(providers.map { provider in
            (provider, ProviderCost.unavailable(provider, reason: errors[provider] ?? "Data source failed."))
        }, uniquingKeysWith: { first, _ in first })
        return ProviderFetch(usages: [:], usageErrors: errors, costs: costs, generatedAt: now)
    }

    private func sourceErrorMessage(source: Source, provider: Provider, error: Error) -> String {
        if source == .codexbar, let engineError = error as? EngineError {
            return EngineAdapter.describe(engineError, provider: provider)
        }
        if let engineError = error as? EngineError {
            return engineError.userMessage
        }
        // Never interpolate the raw error value (an injected source could load it
        // with request/token material) — surface only the error type, as the native
        // clients do.
        return "\(provider.displayName) data source failed (\(type(of: error)))"
    }
}
