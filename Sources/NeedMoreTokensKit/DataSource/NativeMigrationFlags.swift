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

    public static func policy(for provider: Provider, in defaults: UserDefaults = .standard) -> DataSourcePolicy {
        readPolicy(defaults.string(forKey: policyKey(for: provider)))
    }

    public static func policy(for provider: Provider, in values: [String: String]) -> DataSourcePolicy {
        readPolicy(values[policyKey(for: provider)])
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

    private static func readPolicy(_ rawValue: String?) -> DataSourcePolicy {
        guard let rawValue, let policy = DataSourcePolicy(rawValue: rawValue) else { return .auto }
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
