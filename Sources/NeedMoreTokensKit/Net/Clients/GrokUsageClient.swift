import Foundation

/// Surfaces the user's xAI Grok subscription (tier + renewal/trial-end) as a card.
///
/// Why a plan card, not %-used windows: Grok (`grok-build`) and Composer (`grok-composer-2.5-fast`)
/// share ONE Grok subscription. xAI DOES expose per-request/token rate-limit windows, but only as
/// response headers on the quota-CONSUMING chat endpoint (`cli-chat-proxy.grok.com/v1/responses`) —
/// there is no free poll (verified: `/v1/models` has no such headers, an invalid request 422s before
/// the rate-limiter, the CLI doesn't cache the limits to disk, and the web `rate-limits` endpoint
/// 403s OAuth tokens). Polling the chat endpoint would consume the very quota it measures. So NMT
/// reads the FREE, quasi-static subscription (`grok.com/rest/subscriptions`) with the file token,
/// shows the tier + renewal, and caches it so the card stays populated even after the ~6h token lapses.
public struct GrokUsageClient: Sendable {
    private static let subscriptionsURL = URL(string: "https://grok.com/rest/subscriptions")!

    private let credentialLoader: GrokCredentialLoader
    private let tokenStore: TokenStore
    private let httpClient: any HTTPClient
    private let timeout: TimeInterval
    private let cacheTTL: TimeInterval
    private let staleFallbackTTL: TimeInterval

    public init(credentialLoader: GrokCredentialLoader = GrokCredentialLoader(),
                tokenStore: TokenStore = TokenStore(),
                httpClient: any HTTPClient = URLSessionHTTPClient(),
                timeout: TimeInterval = 30,
                cacheTTL: TimeInterval = 6 * 3_600,
                staleFallbackTTL: TimeInterval = 7 * 24 * 3_600) {
        self.credentialLoader = credentialLoader
        self.tokenStore = tokenStore
        self.httpClient = httpClient
        self.timeout = timeout
        self.cacheTTL = cacheTTL
        self.staleFallbackTTL = staleFallbackTTL
    }

    /// The subscription, mapped + cached. `planName` already carries the renewal/trial-end
    /// (e.g. "Grok Pro · trial ends Jun 25") so the card needs no extra field.
    private struct Cache: Codable, Sendable {
        var planName: String
        var fetchedAt: Date
    }

    public func fetch(now: Date = Date()) async -> ProviderPartial {
        // 1. Fresh cache → serve without reading the token or the network (sub data is quasi-static).
        if let cache = tokenStore.load(Cache.self, for: .grok), now.timeIntervalSince(cache.fetchedAt) < cacheTTL {
            return Self.success(planName: cache.planName, updatedAt: cache.fetchedAt)
        }
        // 2. Read the file token + GET the subscription.
        do {
            let credential = try credentialLoader.load(now: now)
            let response = try await httpClient.send(Self.subscriptionsRequest(accessToken: credential.accessToken), timeout: timeout)
            guard response.status == 200 else {
                return staleFallback(now: now) ?? Self.failure("Grok subscription request failed with HTTP \(response.status)")
            }
            let payload = try JSONDecoder().decode(RawGrokSubscriptions.self, from: response.body)
            guard let planName = Self.planName(from: payload) else {
                // Authenticated but no active subscription → free tier, honestly.
                return Self.failure("No active Grok subscription")
            }
            tokenStore.save(Cache(planName: planName, fetchedAt: now), for: .grok)
            return Self.success(planName: planName, updatedAt: now)
        } catch let error as CredentialAccessError {
            // Token expired/absent → keep showing the (static) plan from cache if recent, else re-auth.
            return staleFallback(now: now) ?? Self.failure(error.userMessage)
        } catch {
            return staleFallback(now: now) ?? Self.failure("Grok usage unreadable (\(type(of: error)))")
        }
    }

    /// Serve the cached plan when a live read fails, as long as it isn't too old to trust.
    /// `updatedAt` is the cache's own fetch time so the card shows when the data was REALLY
    /// last refreshed (not "just now"), even when serving days-old fallback data.
    private func staleFallback(now: Date) -> ProviderPartial? {
        guard let cache = tokenStore.load(Cache.self, for: .grok),
              now.timeIntervalSince(cache.fetchedAt) < staleFallbackTTL else { return nil }
        return Self.success(planName: cache.planName, updatedAt: cache.fetchedAt)
    }

    private static func subscriptionsRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: subscriptionsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("grok-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// "Grok Pro · trial ends Jun 25" / "Grok Pro · renews Jul 22", or nil when there's no
    /// active subscription. The renewal is folded into `planName` so it renders on the card's
    /// plan line WITHOUT a usage-style window (a window would wrongly feed the menu-bar
    /// "lowest remaining" number, since Grok's quota windows aren't readable here).
    static func planName(from payload: RawGrokSubscriptions) -> String? {
        // Only an ACTIVE/TRIALING subscription is a live plan. Do NOT fall back to "first" —
        // a cancelled/expired sub still appears in the list, and showing it would both
        // mislabel the card and bill a phantom $30 in the price estimate.
        let active = payload.subscriptions?.first { sub in
            let status = (sub.status ?? "").uppercased()
            return status.contains("ACTIVE") || status.contains("TRIAL")
        }
        guard let sub = active else { return nil }
        let tier = tierName(sub.tier)
        let isTrial = (sub.activeOffer?.type ?? "").uppercased().contains("TRIAL")
        let endISO = isTrial ? (sub.activeOffer?.offerEnd ?? sub.billingPeriodEnd) : (sub.billingPeriodEnd ?? sub.stripe?.currentPeriodEnd)
        guard let end = EngineMapper.parseDate(endISO) else { return tier }
        let when = dateLabel(end)
        return isTrial ? "\(tier) · trial ends \(when)" : "\(tier) · renews \(when)"
    }

    /// "SUBSCRIPTION_TIER_GROK_PRO" → "Grok Pro"; unknown/absent → "Grok".
    private static func tierName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Grok" }
        let core = raw.uppercased().replacingOccurrences(of: "SUBSCRIPTION_TIER_", with: "")
        let words = core.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        let name = words.joined(separator: " ")
        return name.isEmpty ? "Grok" : (name.hasPrefix("Grok") ? name : "Grok \(name)")
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func success(planName: String, updatedAt: Date) -> ProviderPartial {
        ProviderPartial(
            provider: .grok,
            usage: ProviderUsage(provider: .grok, windows: [], accountEmail: nil, planName: planName,
                                 creditsRemaining: nil, exactMonthlyCap: nil, statusIndicator: nil, updatedAt: updatedAt),
            usageError: nil,
            cost: .unavailable(.grok, reason: "Native Grok cost is unavailable."))
    }

    private static func failure(_ message: String) -> ProviderPartial {
        ProviderPartial(provider: .grok, usage: nil, usageError: message,
                        cost: .unavailable(.grok, reason: message))
    }
}

/// Decodes the fields NMT needs from `grok.com/rest/subscriptions`.
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
        // grok.com returns this as an ISO8601 string (verified), but tolerate a Unix-epoch
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
