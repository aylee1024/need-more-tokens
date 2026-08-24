import Foundation

public enum CodexReset {
    public static let grokUsageURL = URL(string: "https://grok.com/?_s=usage")!

    public static func isFeatureVisible(provider: Provider, resetCount: Int?) -> Bool {
        switch provider {
        case .codex, .grok: return resetCount != nil
        default: return false
        }
    }

    public static func bannerText(count: Int) -> String {
        "\(count) reset\(count == 1 ? "" : "s") banked"
    }
}
