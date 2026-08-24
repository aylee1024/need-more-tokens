import Foundation

/// Grok Build and Composer share one SuperGrok weekly pool. This client reads that pool
/// from `GET …/v1/billing?format=credits` (does not consume chat quota), banked usage
/// resets from `ConsumerUiSvc/GetRemainingResets`, and the plan/renewal line from
/// `grok.com/rest/subscriptions`. The plan is cached for 6h because it is quasi-static;
/// credits and remaining resets are fetched every refresh. Access tokens last 6 hours,
/// so NMT refreshes them via `auth.x.ai` and writes the new token back to
/// `~/.grok/auth.json` (grok CLI adopts a sibling write). Never POSTs RedeemReset.
public struct GrokUsageClient: Sendable {
    private static let subscriptionsURL = URL(string: "https://grok.com/rest/subscriptions")!
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    private let credentialLoader: GrokCredentialLoader
    private let tokenStore: TokenStore
    private let httpClient: any HTTPClient
    private let refresher: GrokTokenRefresher
    private let timeout: TimeInterval
    private let cacheTTL: TimeInterval
    private let staleFallbackTTL: TimeInterval

    public init(credentialLoader: GrokCredentialLoader = GrokCredentialLoader(),
                tokenStore: TokenStore = TokenStore(),
                httpClient: any HTTPClient = URLSessionHTTPClient(),
                refresher: GrokTokenRefresher? = nil,
                timeout: TimeInterval = 30,
                cacheTTL: TimeInterval = 6 * 3_600,
                staleFallbackTTL: TimeInterval = 7 * 24 * 3_600) {
        self.credentialLoader = credentialLoader
        self.tokenStore = tokenStore
        self.httpClient = httpClient
        self.refresher = refresher ?? GrokTokenRefresher(httpClient: httpClient, timeout: timeout)
        self.timeout = timeout
        self.cacheTTL = cacheTTL
        self.staleFallbackTTL = staleFallbackTTL
    }

    /// Plan name (quasi-static, 6h TTL) plus the last successful weekly meter.
    /// Windows are cached separately from the plan so an expired 6-hour OIDC token
    /// can still render the last bar instead of a green plan-only card.
    private struct Cache: Codable, Sendable {
        var planName: String
        var fetchedAt: Date
        var windows: [RateWindow]? = nil
        var resetCount: Int? = nil
        var usageFetchedAt: Date? = nil
    }

    public func fetch(now: Date = Date()) async -> ProviderPartial {
        let credential: GrokCredentialLoader.Credential
        do {
            credential = try credentialLoader.load(now: now)
        } catch let error as CredentialAccessError {
            return staleFallback(now: now) ?? Self.failure(error.userMessage)
        } catch {
            return staleFallback(now: now) ?? Self.failure("Grok usage unreadable (\(type(of: error)))")
        }

        var accessToken = credential.accessToken
        if credential.isAccessTokenExpired {
            guard let refreshed = await refreshAccessToken(credential, now: now) else {
                return staleFallback(now: now)
                    ?? Self.failure(CredentialAccessError.expired(provider: .grok).userMessage)
            }
            accessToken = refreshed
        }

        do {
            var creditsResponse = try await httpClient.send(
                Self.creditsRequest(accessToken: accessToken), timeout: timeout)
            if creditsResponse.status == 401, let refreshed = await refreshAccessToken(credential, now: now) {
                accessToken = refreshed
                creditsResponse = try await httpClient.send(
                    Self.creditsRequest(accessToken: accessToken), timeout: timeout)
            }
            guard creditsResponse.status == 200 else {
                if creditsResponse.status == 401 {
                    return staleFallback(now: now)
                        ?? Self.failure(CredentialAccessError.expired(provider: .grok).userMessage)
                }
                return Self.failure("Grok usage request failed with HTTP \(creditsResponse.status)")
            }
            let credits = try JSONDecoder().decode(RawGrokCreditsPayload.self, from: creditsResponse.body)
            let windows = Self.windows(from: credits, now: now)
            let resetCount = await fetchResetCount(accessToken: accessToken, now: now)

            let planName: String?
            if let cache = tokenStore.load(Cache.self, for: .grok),
               now.timeIntervalSince(cache.fetchedAt) < cacheTTL {
                planName = cache.planName
            } else {
                planName = await fetchPlanName(accessToken: accessToken, now: now)
            }

            if planName == nil && windows.isEmpty {
                return Self.failure("No active Grok subscription")
            }
            persistUsage(planName: planName, windows: windows, resetCount: resetCount, now: now)
            return Self.success(planName: planName, windows: windows, resetCount: resetCount, updatedAt: now)
        } catch {
            return staleFallback(now: now) ?? Self.failure("Grok usage unreadable (\(type(of: error)))")
        }
    }

    /// Mint a new access token and write it back to auth.json. Returns nil when there is
    /// no refresh token / client id, or the IdP rejects the grant.
    private func refreshAccessToken(_ credential: GrokCredentialLoader.Credential,
                                    now: Date) async -> String? {
        guard let refreshToken = credential.refreshToken,
              let clientID = credential.clientID else { return nil }
        do {
            let refreshed = try await refresher.refreshed(refreshToken: refreshToken, clientID: clientID)
            let expiresAt = refreshed.expiresIn.map { now.addingTimeInterval($0) } ?? now.addingTimeInterval(6 * 3_600)
            credentialLoader.persistRefreshed(
                accountKey: credential.accountKey,
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: expiresAt)
            return refreshed.accessToken
        } catch {
            return nil
        }
    }

    /// Remember the last live meter so expiry/transport failure can keep the bar.
    private func persistUsage(planName: String?, windows: [RateWindow], resetCount: Int?, now: Date) {
        var cache = tokenStore.load(Cache.self, for: .grok) ?? Cache(
            planName: planName ?? "Grok", fetchedAt: now)
        if let planName {
            cache.planName = planName
        }
        cache.windows = windows
        cache.resetCount = resetCount
        cache.usageFetchedAt = now
        tokenStore.save(cache, for: .grok)
    }

    /// Subscriptions GET is optional once credits succeeded. A 5xx here must not hide the weekly bar.
    private func fetchPlanName(accessToken: String, now: Date) async -> String? {
        do {
            let response = try await httpClient.send(
                Self.subscriptionsRequest(accessToken: accessToken), timeout: timeout)
            guard response.status == 200 else { return nil }
            let payload = try JSONDecoder().decode(RawGrokSubscriptions.self, from: response.body)
            guard let planName = Self.planName(from: payload) else { return nil }
            var cache = tokenStore.load(Cache.self, for: .grok) ?? Cache(planName: planName, fetchedAt: now)
            cache.planName = planName
            cache.fetchedAt = now
            tokenStore.save(cache, for: .grok)
            return planName
        } catch {
            return nil
        }
    }

    /// Serve the last successful meter when a live read fails, as long as it isn't too
    /// old to trust. Plan-name-only cache is NOT a fallback: that produced a green
    /// live card with no weekly bar, which looks like Grok usage isn't implemented.
    /// `updatedAt` is the usage fetch time so the card shows when the meter was REALLY
    /// last refreshed (not "just now").
    private func staleFallback(now: Date) -> ProviderPartial? {
        guard let cache = tokenStore.load(Cache.self, for: .grok) else { return nil }
        let anchor = cache.usageFetchedAt ?? cache.fetchedAt
        guard now.timeIntervalSince(anchor) < staleFallbackTTL else { return nil }
        guard let windows = cache.windows, !windows.isEmpty else { return nil }
        return Self.success(planName: cache.planName, windows: windows,
                            resetCount: cache.resetCount, updatedAt: anchor)
    }

    /// Banked SuperGrok resets. Failure must not hide the weekly bar: grok.com
    /// Settings ▸ Usage is still reachable, and the count is optional chrome.
    private func fetchResetCount(accessToken: String, now: Date) async -> Int? {
        do {
            let response = try await httpClient.send(
                GrokRemainingResets.request(accessToken: accessToken), timeout: timeout)
            guard response.status == 200 else { return nil }
            return GrokRemainingResets.resetCount(fromGrpcWeb: response.body, now: now)
        } catch {
            return nil
        }
    }

    private static func grokJSONGet(_ url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("grok-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func subscriptionsRequest(accessToken: String) -> URLRequest {
        grokJSONGet(subscriptionsURL, accessToken: accessToken)
    }

    private static func creditsRequest(accessToken: String) -> URLRequest {
        grokJSONGet(creditsURL, accessToken: accessToken)
    }

    /// "Grok Pro · trial ends Jun 25" / "Grok Pro · renews Jul 22", or nil when there's no
    /// active subscription. The weekly window is a separate field on the same card.
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

    private static func success(planName: String?, windows: [RateWindow], resetCount: Int?, updatedAt: Date) -> ProviderPartial {
        ProviderPartial(
            provider: .grok,
            usage: ProviderUsage(provider: .grok, windows: windows, accountEmail: nil, planName: planName,
                                 creditsRemaining: nil, exactMonthlyCap: nil, statusIndicator: nil, updatedAt: updatedAt,
                                 resetCount: resetCount),
            usageError: nil,
            cost: .unavailable(.grok, reason: "Native Grok cost is unavailable."))
    }

    private static func failure(_ message: String) -> ProviderPartial {
        ProviderPartial(provider: .grok, usage: nil, usageError: message,
                        cost: .unavailable(.grok, reason: message))
    }

    /// One window for the shared SuperGrok pool. `productUsage` is ignored: those percents
    /// are a breakdown of this same pool, and promoting them to extra windows would make
    /// `tightestWindow` pick a product slice instead of the real remaining quota.
    static func windows(from payload: RawGrokCreditsPayload, now _: Date) -> [RateWindow] {
        guard let config = payload.config else { return [] }
        guard let period = config.currentPeriod,
              let end = EngineMapper.parseDate(period.end) else { return [] }
        let used: Double
        if let percent = config.creditUsagePercent, percent.isFinite, percent >= 0 {
            used = percent
        } else {
            used = 0
        }
        let type = (period.type ?? "").uppercased()
        let windowMinutes: Int
        if let start = EngineMapper.parseDate(period.start) {
            windowMinutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
        } else if type.contains("MONTHLY") {
            windowMinutes = 43_200
        } else {
            windowMinutes = 10_080
        }
        let label: String
        if type.contains("WEEKLY") {
            label = "Weekly"
        } else if type.contains("MONTHLY") {
            label = "Monthly"
        } else {
            label = RateWindow.Period(windowMinutes: windowMinutes).shortLabel
        }
        return [
            RateWindow(
                label: label,
                period: RateWindow.Period(windowMinutes: windowMinutes),
                windowMinutes: windowMinutes,
                usedPercent: used,
                resetsAt: end,
                resetDescription: nil
            )
        ]
    }
}
