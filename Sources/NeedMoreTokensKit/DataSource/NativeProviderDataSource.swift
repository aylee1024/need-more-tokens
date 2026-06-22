import Foundation

public struct NativeProviderDataSource: ProviderDataSource {
    public typealias ClientFetch = @Sendable (Date) async -> ProviderPartial

    private let fetchers: [Provider: ClientFetch]
    private let timeout: TimeInterval

    public init(claudeClient: ClaudeUsageClient = ClaudeUsageClient(),
                codexClient: OpenAICodexClient = OpenAICodexClient(),
                geminiClient: GeminiUsageClient = GeminiUsageClient(),
                grokClient: GrokUsageClient = GrokUsageClient(),
                timeout: TimeInterval = 30) {
        self.init(
            claudeFetch: { now in await claudeClient.fetch(now: now) },
            codexFetch: { now in await codexClient.fetch(now: now) },
            geminiFetch: { now in await geminiClient.fetch(now: now) },
            grokFetch: { now in await grokClient.fetch(now: now) },
            timeout: timeout
        )
    }

    public init(claudeFetch: @escaping ClientFetch,
                codexFetch: @escaping ClientFetch,
                geminiFetch: @escaping ClientFetch,
                grokFetch: @escaping ClientFetch,
                timeout: TimeInterval = 30) {
        self.fetchers = [
            .claude: claudeFetch,
            .codex: codexFetch,
            .gemini: geminiFetch,
            .grok: grokFetch,
        ]
        self.timeout = timeout
    }

    public func fetch(providers: [Provider],
                      cycleAnchorDay: Int,
                      now: Date) async -> ProviderFetch {
        let timeout = self.timeout
        let partials = await withTaskGroup(of: ProviderPartial.self) { group in
            for provider in providers {
                guard let fetcher = fetchers[provider] else { continue }
                group.addTask { await Self.fetchWithTimeout(provider: provider, fetcher: fetcher, now: now, timeout: timeout) }
            }

            var collected: [ProviderPartial] = []
            while let partial = await group.next() {
                collected.append(partial)
            }
            return collected
        }

        var usages: [Provider: ProviderUsage] = [:]
        var usageErrors: [Provider: String] = [:]
        var costs: [Provider: ProviderCost] = [:]
        for partial in partials {
            if let usage = partial.usage { usages[partial.provider] = usage }
            if let error = partial.usageError { usageErrors[partial.provider] = error }
            costs[partial.provider] = partial.cost
        }
        return ProviderFetch(usages: usages, usageErrors: usageErrors, costs: costs, generatedAt: now)
    }

    /// Races the client fetch against a deadline. A client's credential read (e.g. a
    /// Keychain access prompt) happens BEFORE its HTTP timeout and can block, so
    /// without this the whole composite would hang. On timeout we return a
    /// usageError partial so the composite always completes and other providers
    /// stay live.
    private static func fetchWithTimeout(provider: Provider,
                                         fetcher: @escaping ClientFetch,
                                         now: Date,
                                         timeout: TimeInterval) async -> ProviderPartial {
        await withTaskGroup(of: ProviderPartial?.self) { group in
            group.addTask { await fetcher(now) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return nil
            }
            let first = (await group.next()) ?? nil
            group.cancelAll()
            if let partial = first { return partial }
            let message = "\(provider.displayName) timed out"
            return ProviderPartial(provider: provider,
                                   usage: nil,
                                   usageError: message,
                                   cost: .unavailable(provider, reason: message))
        }
    }
}
