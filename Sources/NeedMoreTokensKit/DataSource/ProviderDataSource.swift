import Foundation

public struct ProviderFetch: Sendable, Equatable {
    public var usages: [Provider: ProviderUsage]
    public var usageErrors: [Provider: String]
    public var costs: [Provider: ProviderCost]
    public var generatedAt: Date

    public init(usages: [Provider: ProviderUsage],
                usageErrors: [Provider: String],
                costs: [Provider: ProviderCost],
                generatedAt: Date) {
        self.usages = usages
        self.usageErrors = usageErrors
        self.costs = costs
        self.generatedAt = generatedAt
    }

    public func usage(for provider: Provider) -> ProviderUsage? { usages[provider] }
    public func cost(for provider: Provider) -> ProviderCost? { costs[provider] }
}

/// Data source contract: per-provider failures land in `usageErrors` and are
/// never thrown; only whole-run preconditions throw.
public protocol ProviderDataSource: Sendable {
    func fetch(providers: [Provider], cycleAnchorDay: Int, now: Date) async throws -> ProviderFetch
}

public extension ProviderDataSource {
    /// Convenience: fetch all providers with the default cycle anchor and clock.
    /// This is a DISTINCT zero-argument overload, not the requirement re-declared
    /// with default arguments — default args are not part of a Swift signature, so
    /// re-declaring `fetch(providers:cycleAnchorDay:now:)` here would silently become
    /// the requirement's default witness and recurse forever for any conformer that
    /// forgets to implement it. A zero-arg `fetch()` forwards to the (still mandatory)
    /// requirement instead.
    func fetch() async throws -> ProviderFetch {
        try await fetch(providers: Provider.allCases, cycleAnchorDay: 1, now: Date())
    }
}
