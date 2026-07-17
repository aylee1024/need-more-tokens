import Foundation

// GET https://api.anthropic.com/api/oauth/usage - flat fields verified 2026-06-12;
// modern `limits` array verified 2026-07-17. Anthropic migrated the weekly per-model
// buckets into `limits` (the flat `seven_day_sonnet`/`seven_day_opus` fields now return
// null); the "Weekly · Fable" scoped window exists ONLY in `limits[kind=weekly_scoped]`.

public struct RawClaudeUsagePayload: Decodable, Sendable {
    public let fiveHour: RawClaudeUsageWindow?
    public let sevenDay: RawClaudeUsageWindow?
    public let sevenDaySonnet: RawClaudeUsageWindow?
    public let sevenDayOpus: RawClaudeUsageWindow?
    public let limits: [RawClaudeLimit]?
    public let extraUsage: RawClaudeExtraUsage?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = container.decodeNative(RawClaudeUsageWindow.self, forKey: .fiveHour)
        sevenDay = container.decodeNative(RawClaudeUsageWindow.self, forKey: .sevenDay)
        sevenDaySonnet = container.decodeNative(RawClaudeUsageWindow.self, forKey: .sevenDaySonnet)
        sevenDayOpus = container.decodeNative(RawClaudeUsageWindow.self, forKey: .sevenDayOpus)
        limits = container.decodeNative([RawClaudeLimit].self, forKey: .limits)
        extraUsage = container.decodeNative(RawClaudeExtraUsage.self, forKey: .extraUsage)
    }

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case limits
        case extraUsage = "extra_usage"
    }
}

/// One entry of the modern `limits` array. `kind` is "session" | "weekly_all" |
/// "weekly_scoped"; a scoped weekly entry carries the model it applies to (e.g. "Fable").
public struct RawClaudeLimit: Decodable, Sendable {
    public let kind: String?
    public let group: String?
    public let percent: Double?
    public let resetsAt: String?
    public let scope: RawClaudeLimitScope?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.decodeNative(String.self, forKey: .kind)
        group = container.decodeNative(String.self, forKey: .group)
        percent = container.decodeNative(Double.self, forKey: .percent)
        resetsAt = container.decodeNative(String.self, forKey: .resetsAt)
        scope = container.decodeNative(RawClaudeLimitScope.self, forKey: .scope)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case group
        case percent
        case resetsAt = "resets_at"
        case scope
    }
}

public struct RawClaudeLimitScope: Decodable, Sendable {
    public let model: RawClaudeLimitModel?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = container.decodeNative(RawClaudeLimitModel.self, forKey: .model)
    }

    private enum CodingKeys: String, CodingKey {
        case model
    }
}

public struct RawClaudeLimitModel: Decodable, Sendable {
    public let id: String?
    public let displayName: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeNative(String.self, forKey: .id)
        displayName = container.decodeNative(String.self, forKey: .displayName)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
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
