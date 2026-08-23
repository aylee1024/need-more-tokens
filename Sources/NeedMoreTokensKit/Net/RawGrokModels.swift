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
