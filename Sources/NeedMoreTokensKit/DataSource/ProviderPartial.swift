import Foundation

public struct ProviderPartial: Sendable {
    public let provider: Provider
    public let usage: ProviderUsage?
    public let usageError: String?
    public let cost: ProviderCost
    /// The failure is specifically "this provider needs the user to sign in again", not a
    /// transient one. Typed rather than sniffed from `usageError`, so the UI can offer the
    /// sign-in button on exactly the failures a sign-in actually fixes.
    public let requiresSignIn: Bool

    public init(provider: Provider, usage: ProviderUsage?, usageError: String?, cost: ProviderCost,
                requiresSignIn: Bool = false) {
        self.provider = provider
        self.usage = usage
        self.usageError = usageError
        self.cost = cost
        self.requiresSignIn = requiresSignIn
    }
}
