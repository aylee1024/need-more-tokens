import Foundation

// GET https://chatgpt.com/backend-api/wham/usage - shape verified 2026-06-12.

public struct RateLimitStatusPayload: Decodable, Sendable {
    public let userID: String?
    public let accountID: String?
    public let email: String?
    public let planType: String?
    public let rateLimit: RawCodexRateLimit?
    public let codeReviewRateLimit: RawCodexRateLimit?
    public let additionalRateLimits: RawJSONValue?
    public let credits: RawCodexCredits?
    public let spendControl: RawJSONValue?
    public let rateLimitReachedType: String?
    public let promo: RawJSONValue?
    public let referralBeacon: RawJSONValue?
    public let rateLimitResetCredits: RawCodexRateLimitResetCredits?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = container.decodeNative(String.self, forKey: .userID)
        accountID = container.decodeNative(String.self, forKey: .accountID)
        email = container.decodeNative(String.self, forKey: .email)
        planType = container.decodeNative(String.self, forKey: .planType)
        rateLimit = container.decodeNative(RawCodexRateLimit.self, forKey: .rateLimit)
        codeReviewRateLimit = container.decodeNative(RawCodexRateLimit.self, forKey: .codeReviewRateLimit)
        additionalRateLimits = container.decodeNative(RawJSONValue.self, forKey: .additionalRateLimits)
        credits = container.decodeNative(RawCodexCredits.self, forKey: .credits)
        spendControl = container.decodeNative(RawJSONValue.self, forKey: .spendControl)
        rateLimitReachedType = container.decodeNative(String.self, forKey: .rateLimitReachedType)
        promo = container.decodeNative(RawJSONValue.self, forKey: .promo)
        referralBeacon = container.decodeNative(RawJSONValue.self, forKey: .referralBeacon)
        rateLimitResetCredits = container.decodeNative(RawCodexRateLimitResetCredits.self, forKey: .rateLimitResetCredits)
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case accountID = "account_id"
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case spendControl = "spend_control"
        case rateLimitReachedType = "rate_limit_reached_type"
        case promo
        case referralBeacon = "referral_beacon"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }
}

public struct RawCodexRateLimit: Decodable, Sendable {
    public let primaryWindow: RawCodexRateLimitWindow?
    public let secondaryWindow: RawCodexRateLimitWindow?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryWindow = container.decodeNative(RawCodexRateLimitWindow.self, forKey: .primaryWindow)
        secondaryWindow = container.decodeNative(RawCodexRateLimitWindow.self, forKey: .secondaryWindow)
    }

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

public struct RawCodexRateLimitWindow: Decodable, Sendable {
    public let usedPercent: Double?
    public let limitWindowSeconds: Double?
    public let resetAfterSeconds: Double?
    public let resetAt: Double?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = container.decodeNative(Double.self, forKey: .usedPercent)
        limitWindowSeconds = container.decodeNative(Double.self, forKey: .limitWindowSeconds)
        resetAfterSeconds = container.decodeNative(Double.self, forKey: .resetAfterSeconds)
        resetAt = container.decodeNative(Double.self, forKey: .resetAt)
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

public struct RawCodexCredits: Decodable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let overageLimitReached: Bool?
    public let balance: String?
    public let approxLocalMessages: [Int]?
    public let approxCloudMessages: [Int]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = container.decodeNative(Bool.self, forKey: .hasCredits)
        unlimited = container.decodeNative(Bool.self, forKey: .unlimited)
        overageLimitReached = container.decodeNative(Bool.self, forKey: .overageLimitReached)
        balance = container.decodeNative(String.self, forKey: .balance)
        approxLocalMessages = container.decodeNative([Int].self, forKey: .approxLocalMessages)
        approxCloudMessages = container.decodeNative([Int].self, forKey: .approxCloudMessages)
    }

    private enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case overageLimitReached = "overage_limit_reached"
        case balance
        case approxLocalMessages = "approx_local_messages"
        case approxCloudMessages = "approx_cloud_messages"
    }
}

public struct RawCodexRateLimitResetCredits: Decodable, Sendable {
    public let availableCount: Int?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = container.decodeNative(Int.self, forKey: .availableCount)
    }

    private enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }
}
