import Foundation

public struct ProviderPartial: Sendable {
    public let provider: Provider
    public let usage: ProviderUsage?
    public let usageError: String?
    public let cost: ProviderCost

    public init(provider: Provider, usage: ProviderUsage?, usageError: String?, cost: ProviderCost) {
        self.provider = provider
        self.usage = usage
        self.usageError = usageError
        self.cost = cost
    }
}
