import Foundation

// GET https://api.anthropic.com/api/oauth/usage - shape verified 2026-06-12.

public struct RawClaudeUsagePayload: Decodable, Sendable {
    public let fiveHour: RawClaudeUsageWindow?
    public let sevenDay: RawClaudeUsageWindow?
    public let sevenDaySonnet: RawClaudeUsageWindow?
    public let sevenDayOpus: RawClaudeUsageWindow?
    public let extraUsage: RawClaudeExtraUsage?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = container.decodeNative(RawClaudeUsageWindow.self, forKey: .fiveHour)
        sevenDay = container.decodeNative(RawClaudeUsageWindow.self, forKey: .sevenDay)
        sevenDaySonnet = container.decodeNative(RawClaudeUsageWindow.self, forKey: .sevenDaySonnet)
        sevenDayOpus = container.decodeNative(RawClaudeUsageWindow.self, forKey: .sevenDayOpus)
        extraUsage = container.decodeNative(RawClaudeExtraUsage.self, forKey: .extraUsage)
    }

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
    }
}

public struct RawClaudeUsageWindow: Decodable, Sendable {
    public let utilization: Double?
    public let resetsAt: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = container.decodeNative(Double.self, forKey: .utilization)
        resetsAt = container.decodeNative(String.self, forKey: .resetsAt)
    }

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

public struct RawClaudeExtraUsage: Decodable, Sendable {
    public let isEnabled: Bool?
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?
    public let currency: String?
    public let disabledReason: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = container.decodeNative(Bool.self, forKey: .isEnabled)
        monthlyLimit = container.decodeNative(Double.self, forKey: .monthlyLimit)
        usedCredits = container.decodeNative(Double.self, forKey: .usedCredits)
        utilization = container.decodeNative(Double.self, forKey: .utilization)
        currency = container.decodeNative(String.self, forKey: .currency)
        disabledReason = container.decodeNative(String.self, forKey: .disabledReason)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
        case disabledReason = "disabled_reason"
    }
}
