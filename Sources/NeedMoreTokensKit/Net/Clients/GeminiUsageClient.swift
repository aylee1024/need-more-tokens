import Foundation

public struct GeminiUsageClient: Sendable {
    private static let loadCodeAssistURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    // daily-cloudcode-pa's quota summary omits the Gemini group for this client
    // (only "Claude and GPT models" comes back). A newer User-Agent on that host
    // returns Gemini at remainingFraction 1 with resetTime equal to now plus the
    // window, a placeholder rather than the account's usage. cloudcode-pa returns
    // the real Gemini weekly window. loadCodeAssist stays on daily: that is the
    // host that resolves the project, and the same project id works here.
    private static let retrieveQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    // Gemini 4 Argon is a separate weekly bucket, and cloudcode-pa does not return
    // that group. daily-cloudcode-pa does, but only for a current Antigravity user
    // agent: antigravity/cli/1.0.9 on that host gets no Argon group. The "Gemini
    // Models" group in that same response is the placeholder above, so the Argon
    // request contributes only the Argon group. A failure leaves the shared
    // Gemini windows in place.
    private static let argonQuotaURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    // The grouped quota endpoint gates its response on the Antigravity CLI's
    // User-Agent — without it the server returns empty `groups`. Mirror agy.
    private static let antigravityUserAgent = "antigravity/cli/1.0.9 darwin/arm64"
    private static let argonQuotaUserAgent = "antigravity/cli/1.4.2 darwin/arm64"

    private let credentialStore: CredentialStore
    private let tokenStore: TokenStore
    private let httpClient: any HTTPClient
    private let refresher: GeminiTokenRefresher
    private let timeout: TimeInterval
    private let skew: TimeInterval
    private let refreshMaxAttempts: Int
    private let refreshRetryBaseDelay: TimeInterval

    public init(credentialStore: CredentialStore = CredentialStore(),
                tokenStore: TokenStore = TokenStore(),
                httpClient: any HTTPClient = URLSessionHTTPClient(),
                refresher: GeminiTokenRefresher? = nil,
                timeout: TimeInterval = 30,
                skew: TimeInterval = CredentialExpiry.defaultSkew,
                refreshMaxAttempts: Int = 3,
                refreshRetryBaseDelay: TimeInterval = 0.5) {
        self.credentialStore = credentialStore
        self.tokenStore = tokenStore
        self.httpClient = httpClient
        self.refresher = refresher ?? GeminiTokenRefresher(httpClient: httpClient, timeout: timeout)
        self.timeout = timeout
        self.skew = skew
        self.refreshMaxAttempts = max(1, refreshMaxAttempts)
        self.refreshRetryBaseDelay = refreshRetryBaseDelay
    }

    /// NMT's own cached Gemini tokens (in `TokenStore`). Holds the long-lived refresh token
    /// (Google's is reusable/non-rotating) plus the most recent access token and its expiry,
    /// so the periodic path self-refreshes WITHOUT re-reading agy's Keychain item.
    private struct Cache: Codable, Sendable {
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
    }

    public func fetch(now: Date = Date()) async -> ProviderPartial {
        do {
            let accessToken = try await resolveAccessToken(now: now)
            let project = try await loadProject(accessToken: accessToken)
            let quotaResponse = try await httpClient.send(try Self.retrieveQuotaRequest(accessToken: accessToken, project: project), timeout: timeout)
            guard quotaResponse.status == 200 else {
                // A 401/403 means the (possibly cached) token was rejected/revoked server-side.
                // Drop NMT's cache so the NEXT cycle re-reads/refreshes rather than serving the
                // dead token until its local expiry.
                if Self.isAuthFailure(quotaResponse.status) { tokenStore.clear(for: .gemini) }
                return Self.failure("Gemini quota request failed with HTTP \(quotaResponse.status)")
            }

            let payload = try JSONDecoder().decode(RawGeminiQuotaPayload.self, from: quotaResponse.body)
            let shared = Self.sharedWindows(from: payload)
            var argon = Self.argonWindows(from: payload)
            if argon.isEmpty {
                argon = await argonWindows(accessToken: accessToken, project: project)
            }
            guard let usage = Self.usage(windows: shared + argon, now: now) else {
                return Self.failure("No Gemini quota buckets returned")
            }
            return ProviderPartial(provider: .gemini,
                                   usage: usage,
                                   usageError: nil,
                                   cost: Self.unavailableCost())
        } catch let error as CredentialAccessError {
            // Includes refresh failures, which resolveAccessToken maps to .expired so the
            // card shows the clean "expired — run agy" message instead of an HTTP error.
            return Self.failure(error.userMessage)
        } catch let error as GeminiClientError {
            // Surface the real cause (e.g. the loadCodeAssist HTTP status) instead
            // of the opaque type name, so failures are diagnosable.
            return Self.failure("Gemini usage unreadable: \(error.description)")
        } catch {
            return Self.failure("Gemini usage unreadable (\(type(of: error)))")
        }
    }

    /// A usable Gemini access token, sourced so the periodic path never reads agy's Keychain
    /// item after a one-time bootstrap:
    ///   1. NMT's cached access token, while still valid → no Keychain, no network.
    ///   2. Self-refresh from NMT's stored refresh token (Google's is non-rotating) → no
    ///      Keychain; the refreshed token + expiry are cached for next time.
    ///   3. Bootstrap: read agy's Keychain item ONCE to seed the refresh token (first run, or
    ///      after the stored token was revoked by an agy re-auth), then refresh + cache.
    /// A definitive failure surfaces the clean "expired — run agy" (never a raw "HTTP NNN").
    private func resolveAccessToken(now: Date) async throws -> String {
        let cache = tokenStore.load(Cache.self, for: .gemini) ?? Cache()

        // 1. Cached access token still valid → serve it without touching Keychain or network.
        if let access = cache.accessToken, let expiry = cache.expiresAt,
           expiry > now.addingTimeInterval(skew) {
            return access
        }

        // 2. Refresh from the stored refresh token (no Keychain read).
        if let refresh = cache.refreshToken {
            switch await refreshAndCache(refreshToken: refresh, now: now) {
            case .success(let token):
                return token
            case .exhausted:
                // Transient failures (5xx/429/network) persisted across retries → surface
                // "expired" rather than reading the Keychain (which can't fix a network issue).
                throw CredentialAccessError.expired(provider: .gemini)
            case .noClient, .revoked:
                // noClient: no agy OAuth client configured, so NMT can't self-refresh — fall
                //   back to a Keychain read (the original behavior; agy keeps that token fresh).
                // revoked: the stored refresh token is dead (an agy re-auth rotated it) — read
                //   the Keychain to pick up the new one.
                // Either way fall through to the bootstrap; DON'T get stuck on "expired".
                break
            }
        }

        // 3. Bootstrap from agy's Keychain item — the ONLY Keychain read. Throws
        //    accessNotGranted / missingCredential exactly as before when un-granted/absent.
        let tokens = try credentialStore.loadGeminiTokens(now: now)
        // Use the Keychain's own access token while it is still valid (matches the original
        // behavior, and works even when there is no refresh token). Cache it WITH its expiry
        // (and seed the refresh token), so the next cycles serve it from cache rather than
        // re-reading the Keychain or refreshing immediately. Once it nears expiry, a config'd
        // setup self-refreshes from the stored token; a no-config setup re-reads the Keychain.
        if let access = tokens.accessToken, !tokens.isAccessTokenExpired {
            tokenStore.save(Cache(accessToken: access, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt),
                            for: .gemini)
            return access
        }
        // Access token expired/absent → must self-refresh, which needs a refresh token.
        guard let refresh = tokens.refreshToken else {
            if tokens.accessToken != nil {
                throw CredentialAccessError.expired(provider: .gemini)
            }
            throw CredentialAccessError.missingAccessToken(provider: .gemini)
        }
        switch await refreshAndCache(refreshToken: refresh, now: now) {
        case .success(let token):
            return token
        case .noClient, .revoked, .exhausted:
            throw CredentialAccessError.expired(provider: .gemini)
        }
    }

    /// Default access-token lifetime to assume when a refresh response omits `expires_in`
    /// (Google's are ~1h; 50 min keeps a safety margin).
    private var defaultAccessTokenTTL: TimeInterval { 3_000 }

    private enum RefreshOutcome {
        case success(String)
        case revoked      // 400/401 → the refresh token is invalid (re-bootstrap may help)
        case noClient     // no local OAuth client configured (auto-refresh is opt-in)
        case exhausted    // transient failures (5xx/429/network) persisted across retries
    }

    /// Exchanges the refresh token for a fresh access token and caches it (token + expiry +
    /// the refresh token). Retries transient failures so a momentary Google 5xx/429 doesn't
    /// flip the card to "expired" for a whole cycle.
    private func refreshAndCache(refreshToken: String, now: Date) async -> RefreshOutcome {
        for attempt in 0..<refreshMaxAttempts {
            if attempt > 0, refreshRetryBaseDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(Double(attempt) * refreshRetryBaseDelay * 1_000_000_000))
            }
            do {
                let refreshed = try await refresher.refreshedToken(refreshToken: refreshToken)
                let expiresAt = now.addingTimeInterval(refreshed.expiresIn ?? defaultAccessTokenTTL)
                tokenStore.save(Cache(accessToken: refreshed.accessToken,
                                      refreshToken: refreshToken,
                                      expiresAt: expiresAt),
                                for: .gemini)
                return .success(refreshed.accessToken)
            } catch GeminiRefreshError.clientConfigMissing {
                return .noClient
            } catch GeminiRefreshError.http(let status) where status == 400 || status == 401 {
                return .revoked
            } catch is GeminiRefreshError {
                continue  // transient (5xx/429/malformed/no-token) → retry until exhausted.
            } catch {
                continue
            }
        }
        return .exhausted
    }

    private func loadProject(accessToken: String) async throws -> String {
        let response = try await httpClient.send(try Self.loadCodeAssistRequest(accessToken: accessToken), timeout: timeout)
        guard response.status == 200 else {
            // Token rejected/revoked → drop the cache so the next cycle re-reads/refreshes.
            if Self.isAuthFailure(response.status) { tokenStore.clear(for: .gemini) }
            throw GeminiClientError.http("Gemini Code Assist project request failed with HTTP \(response.status)")
        }
        let payload = try JSONDecoder().decode(RawGeminiLoadCodeAssistPayload.self, from: response.body)
        guard let project = payload.cloudaicompanionProject, !project.isEmpty else {
            throw GeminiClientError.http("Gemini Code Assist project missing")
        }
        return project
    }

    private static func loadCodeAssistRequest(accessToken: String) throws -> URLRequest {
        var request = URLRequest(url: loadCodeAssistURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(antigravityUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "ideType": "ANTIGRAVITY",
            ],
        ])
        return request
    }

    private static func retrieveQuotaRequest(accessToken: String, project: String) throws -> URLRequest {
        try quotaRequest(url: retrieveQuotaURL, userAgent: antigravityUserAgent, accessToken: accessToken, project: project)
    }

    private static func argonQuotaRequest(accessToken: String, project: String) throws -> URLRequest {
        try quotaRequest(url: argonQuotaURL, userAgent: argonQuotaUserAgent, accessToken: accessToken, project: project)
    }

    private static func quotaRequest(url: URL, userAgent: String, accessToken: String, project: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["project": project])
        return request
    }

    /// Argon quota from daily-cloudcode-pa. Any failure, including an auth status,
    /// is ignored: the shared Gemini windows already succeeded with this token, and
    /// clearing the cache here would drop a token the primary host just accepted.
    private func argonWindows(accessToken: String, project: String) async -> [RateWindow] {
        do {
            let response = try await httpClient.send(try Self.argonQuotaRequest(accessToken: accessToken, project: project), timeout: timeout)
            guard response.status == 200 else { return [] }
            let payload = try JSONDecoder().decode(RawGeminiQuotaPayload.self, from: response.body)
            return Self.argonWindows(from: payload)
        } catch {
            return []
        }
    }

    private static func usage(windows: [RateWindow], now: Date) -> ProviderUsage? {
        guard !windows.isEmpty else { return nil }

        return ProviderUsage(
            provider: .gemini,
            windows: windows,
            accountEmail: nil,
            planName: nil,
            creditsRemaining: nil,
            exactMonthlyCap: nil,
            statusIndicator: nil,
            updatedAt: now
        )
    }

    /// Shared Flash/Pro windows. Argon buckets are excluded here even when a
    /// renamed group makes the fallback match every `gemini-` id: an Argon
    /// bucket labeled "Weekly" would hide behind the shared weekly bar.
    private static func sharedWindows(from payload: RawGeminiQuotaPayload) -> [RateWindow] {
        let groups = (payload.groups ?? []).filter { !isArgonGroup($0) }
        let geminiGroups = groups.filter { $0.displayName == "Gemini Models" }
        let buckets: [RawGeminiQuotaBucket]
        if geminiGroups.isEmpty {
            buckets = groups
                .flatMap { $0.buckets ?? [] }
                .filter { bucket in
                    guard let id = bucket.bucketId else { return false }
                    return id.hasPrefix("gemini-") && !isArgonBucket(id)
                }
        } else {
            buckets = geminiGroups.flatMap { $0.buckets ?? [] }.filter { bucket in
                guard let id = bucket.bucketId else { return true }
                return !isArgonBucket(id)
            }
        }
        return rateWindows(from: buckets, modelTag: nil)
    }

    /// Gemini 4 Argon only. A group named for Argon contributes every bucket.
    /// An Argon bucket sitting inside another group contributes only itself, so
    /// a shared Flash/Pro bucket in that group is not relabeled as Argon. The
    /// daily host's "Gemini Models" group is not an Argon group and is not read.
    private static func argonWindows(from payload: RawGeminiQuotaPayload) -> [RateWindow] {
        let buckets = (payload.groups ?? []).flatMap { group -> [RawGeminiQuotaBucket] in
            if isArgonGroup(group) { return group.buckets ?? [] }
            return (group.buckets ?? []).filter { bucket in
                guard let id = bucket.bucketId else { return false }
                return isArgonBucket(id)
            }
        }
        return rateWindows(from: buckets, modelTag: "Argon")
    }

    private static func isArgonGroup(_ group: RawGeminiQuotaGroup) -> Bool {
        if group.displayName?.localizedCaseInsensitiveContains("argon") == true { return true }
        let buckets = group.buckets ?? []
        guard !buckets.isEmpty else { return false }
        return buckets.allSatisfy { bucket in
            guard let id = bucket.bucketId else { return false }
            return isArgonBucket(id)
        }
    }

    private static func isArgonBucket(_ bucketId: String) -> Bool {
        bucketId.localizedCaseInsensitiveContains("argon")
    }

    private static func rateWindows(from buckets: [RawGeminiQuotaBucket], modelTag: String?) -> [RateWindow] {
        buckets.compactMap { bucket -> RateWindow? in
            guard let remaining = bucket.remainingFraction,
                  remaining.isFinite else { return nil }
            let period = period(for: bucket.window)
            // Match the Claude/Codex card style: terse period label ("5-hour" /
            // "Weekly") and let the UI render "Resets in X" from resetsAt rather
            // than the server's verbose `description` sentence. Argon is its own
            // pool, so the label names it the way "Weekly · Fable" names Claude's.
            let label = modelTag.map { "\(period.shortLabel) · \($0)" } ?? period.shortLabel
            return RateWindow(
                label: label,
                period: period,
                windowMinutes: windowMinutes(for: period),
                usedPercent: clampPercent((1 - remaining) * 100),
                resetsAt: EngineMapper.parseDate(bucket.resetTime),
                resetDescription: nil
            )
        }
        .sorted { $0.windowMinutes < $1.windowMinutes }
    }

    private static func period(for window: String?) -> RateWindow.Period {
        // Antigravity sends "weekly" and "5h" today; parse defensively so a new
        // window type (e.g. "daily", "3h", "30d") is not silently shown as 5-hour.
        switch window {
        case "weekly": return .weekly
        case "5h": return .fiveHour
        case "daily", "1d": return .daily
        case let w?:
            if w.hasSuffix("h"), let n = Int(w.dropLast()), n > 0 { return RateWindow.Period(windowMinutes: n * 60) }
            if w.hasSuffix("d"), let n = Int(w.dropLast()), n > 0 { return RateWindow.Period(windowMinutes: n * 1_440) }
            return .fiveHour
        case nil:
            return .fiveHour
        }
    }

    private static func windowMinutes(for period: RateWindow.Period) -> Int {
        switch period {
        case .fiveHour: 300
        case .daily: 1_440
        case .weekly: 10_080
        case .other(let minutes): minutes
        }
    }

    private static func isAuthFailure(_ status: Int) -> Bool {
        status == 401 || status == 403
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func unavailableCost() -> ProviderCost {
        .unavailable(.gemini, reason: "Native Gemini cost is unavailable.")
    }

    private static func failure(_ message: String) -> ProviderPartial {
        ProviderPartial(provider: .gemini,
                        usage: nil,
                        usageError: message,
                        cost: .unavailable(.gemini, reason: message))
    }
}

private enum GeminiClientError: Error, Sendable, CustomStringConvertible {
    case http(String)

    var description: String {
        switch self {
        case .http(let message): message
        }
    }
}
