import Foundation

public enum CodexReset {
    public static let grokUsageURL = URL(string: "https://grok.com/?_s=usage")!

    public static func isFeatureVisible(provider: Provider, resetCount: Int?) -> Bool {
        switch provider {
        case .codex, .grok: return resetCount != nil
        default: return false
        }
    }

    public static func bannerText(count: Int, expiresAt: Date? = nil) -> String {
        let base = "\(count) reset\(count == 1 ? "" : "s") banked"
        guard count > 0, let expiresAt else { return base }
        let when = expiresAt.formatted(date: .abbreviated, time: .shortened)
        if count == 1 { return "\(base), expires \(when)" }
        return "\(base), soonest expires \(when)"
    }
}
