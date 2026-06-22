import Foundation

/// Per-provider on/off for usage tracking, persisted in UserDefaults.
///
/// Default is **ON**: an absent key means enabled, so existing users keep all providers and
/// a newly added provider (e.g. Grok) is tracked until the user turns it off. A disabled
/// provider is neither fetched (no HTTP, no Keychain read) nor shown as a card — turning it
/// off genuinely stops tracking, it doesn't just hide the card. Stored as a `Bool` per
/// provider under `providerEnabled.<rawValue>`, matching the `PriceOverrides` key convention.
public enum ProviderToggles {
    public static func key(for provider: Provider) -> String {
        "providerEnabled.\(provider.rawValue)"
    }

    /// Whether the provider's tracking is enabled. Absent key ⇒ ON (default), so the toggle
    /// is opt-out, not opt-in.
    public static func isEnabled(_ provider: Provider, in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key(for: provider)) != nil else { return true }
        return defaults.bool(forKey: key(for: provider))
    }

    /// The enabled providers, preserving `Provider.allCases` order (so card order is stable).
    public static func loadEnabled(from defaults: UserDefaults = .standard) -> [Provider] {
        Provider.allCases.filter { isEnabled($0, in: defaults) }
    }

    public static func setEnabled(_ enabled: Bool, for provider: Provider, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key(for: provider))
    }
}
