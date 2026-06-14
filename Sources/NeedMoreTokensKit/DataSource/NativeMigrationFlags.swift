import Foundation

public enum DataSourcePolicy: String, Sendable, CaseIterable {
    case auto
    case native
    case codexbar
}

public enum NativeMigrationFlags {
    public static let fallbackOnErrorKey = "nmt.dataSource.fallbackOnError"

    public static func policyKey(for provider: Provider) -> String {
        "nmt.dataSource.\(provider.rawValue)"
    }

    /// Default source when the user hasn't chosen one.
    /// Claude's OAuth token lives ONLY in the macOS Keychain, and macOS prompts any app
    /// reading a Keychain item it lacks a persistent ACL grant for. A freshly installed/
    /// re-signed NMT has no such grant (codexbar, a long-trusted stable binary, does and
    /// reads it silently), so reading Claude natively re-prompts. Default Claude to
    /// codexbar (silent) to avoid that; Codex and Gemini read plain credential FILES
    /// (~/.codex, ~/.gemini) — no Keychain, no prompt — so they default native-first.
    public static func defaultPolicy(for provider: Provider) -> DataSourcePolicy {
        switch provider {
        case .claude: .codexbar
        case .codex, .gemini: .auto
        }
    }

    public static func policy(for provider: Provider, in defaults: UserDefaults = .standard) -> DataSourcePolicy {
        readPolicy(defaults.string(forKey: policyKey(for: provider)), default: defaultPolicy(for: provider))
    }

    public static func policy(for provider: Provider, in values: [String: String]) -> DataSourcePolicy {
        readPolicy(values[policyKey(for: provider)], default: defaultPolicy(for: provider))
    }

    public static func fallbackOnError(in defaults: UserDefaults = .standard) -> Bool {
        guard let value = defaults.object(forKey: fallbackOnErrorKey) else { return true }
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return readBool(string) ?? true }
        if let number = value as? NSNumber { return number.boolValue }
        return true
    }

    public static func fallbackOnError(in values: [String: String]) -> Bool {
        readBool(values[fallbackOnErrorKey]) ?? true
    }

    private static func readPolicy(_ rawValue: String?, default fallback: DataSourcePolicy) -> DataSourcePolicy {
        guard let rawValue, let policy = DataSourcePolicy(rawValue: rawValue) else { return fallback }
        return policy
    }

    private static func readBool(_ rawValue: String?) -> Bool? {
        guard let rawValue else { return nil }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1", "on": return true
        case "false", "no", "0", "off": return false
        default: return nil
        }
    }
}
