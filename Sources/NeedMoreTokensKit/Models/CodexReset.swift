public enum CodexReset {
    public static func isFeatureVisible(provider: Provider, resetCount: Int?) -> Bool {
        provider == .codex && resetCount != nil
    }

    public static func bannerText(count: Int) -> String {
        "\(count) reset\(count == 1 ? "" : "s") banked"
    }
}
