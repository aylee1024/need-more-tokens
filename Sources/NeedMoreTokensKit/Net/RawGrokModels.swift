import Foundation

/// Fields NMT needs from `GET grok.com/rest/subscriptions`.
struct RawGrokSubscriptions: Decodable {
    let subscriptions: [Subscription]?

    struct Subscription: Decodable {
        let tier: String?
        let status: String?
        let billingPeriodEnd: String?
        let activeOffer: ActiveOffer?
        let stripe: Stripe?
    }
    struct ActiveOffer: Decodable {
        let type: String?
        let offerEnd: String?
    }
    struct Stripe: Decodable {
        let currentPeriodEnd: String?
        // grok.com returns this as an ISO8601 string, but tolerate a Unix-epoch
        // number too so a field-type drift degrades to nil rather than failing the decode.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try? c.decodeIfPresent(String.self, forKey: .currentPeriodEnd) {
                currentPeriodEnd = s
            } else if let n = try? c.decodeIfPresent(Double.self, forKey: .currentPeriodEnd) {
                let f = ISO8601DateFormatter()
                currentPeriodEnd = f.string(from: Date(timeIntervalSince1970: n))
            } else {
                currentPeriodEnd = nil
            }
        }
        private enum CodingKeys: String, CodingKey { case currentPeriodEnd }
    }
}

/// `GET cli-chat-proxy.grok.com/v1/billing?format=credits`. `creditUsagePercent` is already
/// 0–100 used of the shared SuperGrok weekly pool. `productUsage` is a breakdown of that
/// same pool, not independent caps, and must not be decoded into RateWindows.
struct RawGrokCreditsPayload: Decodable, Sendable {
    let config: RawGrokCreditsConfig?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = c.decodeNative(RawGrokCreditsConfig.self, forKey: .config)
    }
    private enum CodingKeys: String, CodingKey { case config }
}

struct RawGrokCreditsConfig: Decodable, Sendable {
    let currentPeriod: RawGrokUsagePeriod?
    let creditUsagePercent: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentPeriod = c.decodeNative(RawGrokUsagePeriod.self, forKey: .currentPeriod)
        creditUsagePercent = c.decodeNative(Double.self, forKey: .creditUsagePercent)
    }
    private enum CodingKeys: String, CodingKey {
        case currentPeriod, creditUsagePercent
    }
}

struct RawGrokUsagePeriod: Decodable, Sendable {
    let type: String?
    let start: String?
    let end: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.decodeNative(String.self, forKey: .type)
        start = c.decodeNative(String.self, forKey: .start)
        end = c.decodeNative(String.self, forKey: .end)
    }
    private enum CodingKeys: String, CodingKey { case type, start, end }
}

/// `POST api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus`.
/// Cursor's protocol calls Grok Bot "Sand". `usagePercent` is already percent
/// used (0–100), the same number the Grok Bot app stores as `percentUsed`.
/// A value under 1 is under one percent, not a 0–1 fraction.
struct RawGrokBotUsage: Decodable, Sendable {
    let currentPeriodStart: String?
    let nextResetTimestampUtc: String?
    let usagePercent: Double?
    let hasNonZeroIncludedLimit: Bool?
    let includedLimitZero: Bool?
    let usesPooledEnterpriseAllowance: Bool?
    let sandTrialExpiresAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FlexKey.self)
        currentPeriodStart = c.flexString("currentPeriodStart", "current_period_start")
        nextResetTimestampUtc = c.flexString("nextResetTimestampUtc", "next_reset_timestamp_utc")
        usagePercent = c.flexDouble("usagePercent", "usage_percent")
        hasNonZeroIncludedLimit = c.flexBool("hasNonZeroIncludedLimit", "has_non_zero_included_limit")
        includedLimitZero = c.flexBool("includedLimitZero", "included_limit_zero")
        usesPooledEnterpriseAllowance = c.flexBool("usesPooledEnterpriseAllowance", "uses_pooled_enterprise_allowance")
        sandTrialExpiresAt = c.flexString("sandTrialExpiresAt", "sand_trial_expires_at")
    }
}

private struct FlexKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where K == FlexKey {
    func flexString(_ names: String...) -> String? {
        for name in names {
            guard let key = FlexKey(stringValue: name) else { continue }
            if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        }
        return nil
    }

    func flexDouble(_ names: String...) -> Double? {
        for name in names {
            guard let key = FlexKey(stringValue: name) else { continue }
            if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        }
        return nil
    }

    func flexBool(_ names: String...) -> Bool? {
        for name in names {
            guard let key = FlexKey(stringValue: name) else { continue }
            if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        }
        return nil
    }
}
