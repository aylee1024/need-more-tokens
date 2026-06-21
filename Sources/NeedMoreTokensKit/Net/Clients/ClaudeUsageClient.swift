import Foundation

public struct ClaudeUsageClient: Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let credentialLoader: ClaudeCredentialLoader
    private let httpClient: any HTTPClient
    private let timeout: TimeInterval

    public init(keychainReader: any KeychainReading = SystemKeychainReader(),
                httpClient: any HTTPClient = URLSessionHTTPClient(),
                timeout: TimeInterval = 30,
                service: String = ClaudeCredentialLoader.defaultService,
                account: String? = ClaudeCredentialLoader.defaultAccount) {
        self.credentialLoader = ClaudeCredentialLoader(keychainReader: keychainReader, service: service, account: account)
        self.httpClient = httpClient
        self.timeout = timeout
    }

    public func fetch(now: Date = Date()) async -> ProviderPartial {
        do {
            let credential = try credentialLoader.load(now: now)
            let response = try await httpClient.send(Self.request(accessToken: credential.accessToken), timeout: timeout)
            guard response.status == 200 else {
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
        } catch {
            return Self.failure("Claude usage unreadable (\(type(of: error)))")
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
