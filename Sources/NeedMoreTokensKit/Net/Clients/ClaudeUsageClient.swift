import Foundation

public struct ClaudeUsageClient: Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let credentialLoader: ClaudeCredentialLoader
    private let ownStore: ClaudeOAuthStore
    private let claudeRefresher: ClaudeTokenRefresher
    private let tokenStore: TokenStore
    private let httpClient: any HTTPClient
    private let timeout: TimeInterval
    private let skew: TimeInterval

    public init(keychainReader: any KeychainReading = SystemKeychainReader(),
                ownStore: ClaudeOAuthStore = ClaudeOAuthStore(),
                claudeRefresher: ClaudeTokenRefresher? = nil,
                tokenStore: TokenStore = TokenStore(),
                httpClient: any HTTPClient = URLSessionHTTPClient(),
                timeout: TimeInterval = 30,
                skew: TimeInterval = CredentialExpiry.defaultSkew,
                service: String = ClaudeCredentialLoader.defaultService,
                account: String? = ClaudeCredentialLoader.defaultAccount) {
        self.credentialLoader = ClaudeCredentialLoader(keychainReader: keychainReader, service: service, account: account)
        self.ownStore = ownStore
        self.claudeRefresher = claudeRefresher ?? ClaudeTokenRefresher(httpClient: httpClient, timeout: timeout)
        self.tokenStore = tokenStore
        self.httpClient = httpClient
        self.timeout = timeout
        self.skew = skew
    }

    /// NMT's cached Claude access token (in `TokenStore`). Anthropic ROTATES Claude's refresh
    /// token, so NMT must NOT hold or refresh one — doing so would invalidate Claude Code and
    /// force a CLI re-login. NMT therefore only ever READS the Keychain, and caches the access
    /// token for its full ~8h life so it reads the Keychain ~once per token, not every cycle.
    private struct Cache: Codable, Sendable {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
        var scopes: [String]?
    }

    public func fetch(now: Date = Date()) async -> ProviderPartial {
        do {
            let credential = try await resolveAccess(now: now)
            let response = try await httpClient.send(Self.request(accessToken: credential.accessToken), timeout: timeout)
            guard response.status == 200 else {
                // A 401/403 means the token was rejected/revoked server-side. Invalidate so the
                // next cycle gets a fresh one: for NMT's own token force a refresh; for the
                // Keychain-fallback path drop the cache so it re-reads.
                if response.status == 401 || response.status == 403 { invalidateAccess() }
                return Self.failure("Claude usage request failed with HTTP \(response.status)")
            }

            let payload = try JSONDecoder().decode(RawClaudeUsagePayload.self, from: response.body)
            guard let usage = Self.usage(from: payload, credential: credential, now: now) else {
                return Self.failure("No Claude usage data returned")
            }
            return ProviderPartial(provider: .claude,
                                   usage: usage,
                                   usageError: nil,
                                   cost: Self.unavailableCost())
        } catch let error as CredentialAccessError {
            return Self.failure(error.userMessage)
        } catch let error as ClaudeRefreshError {
            // Transient refresh failure → temporary, retried next cycle (not a re-auth demand).
            return Self.failure("Claude usage temporarily unavailable (\(error))")
        } catch {
            return Self.failure("Claude usage unreadable (\(type(of: error)))")
        }
    }

    /// Resolves a Claude access token.
    ///
    /// PRIMARY path — NMT's OWN OAuth token (`ClaudeOAuthStore`): if present, use it and NEVER
    /// touch the Keychain. While the access token is valid, return it; once it nears expiry,
    /// self-refresh and WRITE BACK the rotated refresh token (Anthropic rotates it — persisting
    /// the new one is load-bearing). Because this path never reads Claude Code's Keychain item,
    /// Claude Code's periodic token rewrite can't evict NMT — that's what makes Claude permanent.
    ///
    /// FALLBACK path — only when NMT has no own token (never set up): the previous behavior of
    /// reading the Keychain (cached for the token's life). Subject to the eviction, but it keeps
    /// a not-yet-onboarded install working.
    private func resolveAccess(now: Date) async throws -> ClaudeCredentialAccess {
        if var own = ownStore.load() {
            if let expiry = own.expiresAt, expiry > now.addingTimeInterval(skew) {
                return Self.access(from: own)
            }
            do {
                let refreshed = try await claudeRefresher.refreshed(refreshToken: own.refreshToken, clientID: own.clientID)
                own.accessToken = refreshed.accessToken
                own.refreshToken = refreshed.refreshToken          // ROTATED — must persist
                own.expiresAtEpoch = now.addingTimeInterval(refreshed.expiresIn ?? 28_800).timeIntervalSince1970
                ownStore.save(own)
                return Self.access(from: own)
            } catch ClaudeRefreshError.http(let status) where status == 400 || status == 401 || status == 403 {
                // ONLY a definitive auth rejection means the refresh token is revoked (signed out
                // everywhere) → re-auth needed. Do NOT fall back to the Keychain here (that would
                // reintroduce the eviction we just eliminated). The user re-runs the one-time sign-in.
                throw CredentialAccessError.invalidCredential(
                    provider: .claude,
                    message: "Claude sign-in expired — re-run the one-time NMT Claude setup")
            }
            // Transient refresh failures (5xx / 429 / network / malformed) propagate as-is, so the
            // card shows a temporary error and the NEXT cycle retries — never a wrong "re-run setup".
        }

        // Fallback (no own token configured): Keychain, cached for the token's life.
        if let cache = tokenStore.load(Cache.self, for: .claude),
           let expiry = cache.expiresAt, expiry > now.addingTimeInterval(skew) {
            return ClaudeCredentialAccess(accessToken: cache.accessToken,
                                          subscriptionType: cache.subscriptionType,
                                          scopes: cache.scopes,
                                          expiresAt: expiry.timeIntervalSince1970 * 1_000)
        }
        let access = try credentialLoader.load(now: now)
        let expiresAt = access.expiresAt.map { Date(timeIntervalSince1970: $0 / 1_000) }
        tokenStore.save(Cache(accessToken: access.accessToken,
                              expiresAt: expiresAt,
                              subscriptionType: access.subscriptionType,
                              scopes: access.scopes),
                        for: .claude)
        return access
    }

    private static func access(from own: ClaudeOAuthToken) -> ClaudeCredentialAccess {
        ClaudeCredentialAccess(accessToken: own.accessToken,
                               subscriptionType: own.subscriptionType,
                               scopes: nil,
                               expiresAt: own.expiresAtEpoch.map { $0 * 1_000 })
    }

    /// On a server-side token rejection (401/403): for NMT's own token, force a refresh next
    /// cycle (mark it expired + persist); for the Keychain fallback, drop the cache so it re-reads.
    private func invalidateAccess() {
        if var own = ownStore.load() {
            own.expiresAtEpoch = 0
            ownStore.save(own)
        } else {
            tokenStore.clear(for: .claude)
        }
    }

    private static func request(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func usage(from payload: RawClaudeUsagePayload,
                              credential: ClaudeCredentialAccess,
                              now: Date) -> ProviderUsage? {
        let windows = [
            window(from: payload.fiveHour, label: EngineMapper.windowLabel(provider: .claude, position: 0, windowMinutes: 300), minutes: 300),
            window(from: payload.sevenDay, label: EngineMapper.windowLabel(provider: .claude, position: 1, windowMinutes: 10_080), minutes: 10_080),
            window(from: payload.sevenDaySonnet, label: EngineMapper.windowLabel(provider: .claude, position: 2, windowMinutes: 10_080), minutes: 10_080),
            window(from: payload.sevenDayOpus, label: "Weekly · Opus", minutes: 10_080),
        ].compactMap { $0 }

        let monthlyCap = monetaryCap(from: payload.extraUsage)
        guard !windows.isEmpty || monthlyCap != nil else { return nil }

        return ProviderUsage(
            provider: .claude,
            windows: windows,
            accountEmail: nil,
            planName: planName(from: credential.subscriptionType),
            creditsRemaining: nil,
            exactMonthlyCap: monthlyCap,
            statusIndicator: nil,
            updatedAt: now
        )
    }

    private static func window(from raw: RawClaudeUsageWindow?, label: String, minutes: Int) -> RateWindow? {
        guard let raw, let usedPercent = raw.utilization else { return nil }
        return RateWindow(
            label: label,
            period: RateWindow.Period(windowMinutes: minutes),
            windowMinutes: minutes,
            usedPercent: clampPercent(usedPercent),
            resetsAt: EngineMapper.parseDate(raw.resetsAt),
            resetDescription: nil
        )
    }

    private static func monetaryCap(from raw: RawClaudeExtraUsage?) -> MonetaryCap? {
        guard let raw,
              raw.isEnabled == true,
              let used = raw.usedCredits,
              let limit = raw.monthlyLimit else { return nil }
        // Anthropic's `extra_usage` amounts are in CENTS (verified: a real $1,000 cap
        // arrives as monthly_limit=100000). MonetaryCap is in dollars, so convert here.
        return MonetaryCap(
            used: EngineMapper.sanitizeMoney(used / 100),
            limit: EngineMapper.sanitizeMoney(limit / 100),
            currencyCode: raw.currency ?? "USD",
            periodLabel: "Monthly cap"
        )
    }

    private static func planName(from subscriptionType: String?) -> String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        if subscriptionType.lowercased() == "max" { return "Claude Max" }
        return subscriptionType.capitalized
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func unavailableCost() -> ProviderCost {
        .unavailable(.claude, reason: "Native Claude cost is unavailable.")
    }

    private static func failure(_ message: String) -> ProviderPartial {
        ProviderPartial(provider: .claude,
                        usage: nil,
                        usageError: message,
                        cost: .unavailable(.claude, reason: message))
    }
}
