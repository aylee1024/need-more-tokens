import Foundation

/// Per-provider monthly subscription-price overrides, persisted in UserDefaults.
///
/// The app shows the detected list price by default (`Subscriptions.defaultMonthlyUSD`),
/// but a provider's plan name does not always resolve the exact tier. A user override
/// settles that and also covers any future price drift. Stored as a `Double` per
/// provider; **0 or absent means "no override — use the detected default"**.
public enum PriceOverrides {
    public static func key(for provider: Provider) -> String {
        "priceOverrideUSD.\(provider.rawValue)"
    }

    /// The non-zero overrides as a `[Provider: Double]`, ready for `build(subscriptionOverrides:)`.
    public static func load(from defaults: UserDefaults = .standard) -> [Provider: Double] {
        var overrides: [Provider: Double] = [:]
        for provider in Provider.allCases {
            let value = defaults.double(forKey: key(for: provider))
            if value > 0 { overrides[provider] = value }
        }
        return overrides
    }

    /// Normalizes an edited price for storage: clamps to `>= 0`, and treats a value within a
    /// cent of the detected default as `0` ("track the default"). This is what stops merely
    /// focusing/committing the shown default from pinning it as a permanent override. Pure so
    /// the just-fixed pinning bug has a unit-tested regression guard.
    public static func normalize(_ newValue: Double, default detected: Double?) -> Double {
        let clamped = max(0, newValue)
        if let detected, abs(clamped - detected) < 0.005 { return 0 }
        return clamped
    }
}
