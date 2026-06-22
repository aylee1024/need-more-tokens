import Foundation

/// Shared mapping helpers used by the native provider clients.
public enum EngineMapper {
    /// Display label for a rate-limit window.
    static func windowLabel(provider: Provider, position: Int, windowMinutes: Int) -> String {
        switch provider {
        case .gemini:
            switch position {
            case 0: return "Pro"
            case 1: return "Flash"
            case 2: return "Flash Lite"
            default: return RateWindow.Period(windowMinutes: windowMinutes).shortLabel
            }
        case .claude:
            if windowMinutes == 10080, position >= 2 { return "Weekly · Sonnet" }
            return RateWindow.Period(windowMinutes: windowMinutes).shortLabel
        case .codex:
            return RateWindow.Period(windowMinutes: windowMinutes).shortLabel
        case .grok:
            return RateWindow.Period(windowMinutes: windowMinutes).shortLabel
        }
    }

    /// Clamps a money value to a finite, non-negative number so a bad datum never
    /// poisons a sum or renders as "NaN".
    static func sanitizeMoney(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }

    /// Parses the engine's ISO8601 timestamps (with or without fractional seconds).
    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
