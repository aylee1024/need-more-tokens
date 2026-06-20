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

    /// Default source when the user hasn't chosen one: fully native for every provider.
    /// Codex reads ~/.codex/auth.json (a file); Claude and Gemini read the macOS Keychain
    /// (Claude Code and Antigravity store their tokens there, with no file equivalent).
    /// A background Keychain read can never present a prompt because the app disables
    /// Keychain UI process-wide (`KeychainInteraction.disableBackgroundPrompts`); the user
    /// grants access once via Settings ▸ Enable native access, after which native reads
    /// return data silently. codexbar is retired from the default path and kept only as a
    /// manual per-provider option.
    public static func defaultPolicy(for provider: Provider) -> DataSourcePolicy {
        .native
    }

    public static func policy(for provider: Provider, in defaults: UserDefaults = .standard) -> DataSourcePolicy {
        readPolicy(defaults.string(forKey: policyKey(for: provider)), default: defaultPolicy(for: provider))
    }

    public static func policy(for provider: Provider, in values: [String: String]) -> DataSourcePolicy {
        readPolicy(values[policyKey(for: provider)], default: defaultPolicy(for: provider))
    }

    /// codexbar is retired from the default path, so a native error does NOT silently fall
    /// back to codexbar unless the user explicitly turns this on. Default OFF.
    public static func fallbackOnError(in defaults: UserDefaults = .standard) -> Bool {
        guard let value = defaults.object(forKey: fallbackOnErrorKey) else { return false }
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return readBool(string) ?? false }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    public static func fallbackOnError(in values: [String: String]) -> Bool {
        readBool(values[fallbackOnErrorKey]) ?? false
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
