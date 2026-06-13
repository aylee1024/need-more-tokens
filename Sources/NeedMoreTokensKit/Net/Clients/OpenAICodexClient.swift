import Foundation

public struct OpenAICodexClient: Sendable {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let credentialStore: CredentialStore
    private let httpClient: any HTTPClient
    private let timeout: TimeInterval

    public init(credentialStore: CredentialStore = CredentialStore(),
                httpClient: any HTTPClient = URLSessionHTTPClient(),
                timeout: TimeInterval = 30) {
        self.credentialStore = credentialStore
        self.httpClient = httpClient
        self.timeout = timeout
    }

    public func fetch(now: Date = Date()) async -> ProviderPartial {
        do {
            let credential = try credentialStore.loadCodexAccess(now: now)
            let response = try await httpClient.send(Self.request(credential: credential), timeout: timeout)
            guard response.status == 200 else {
                return Self.failure("Codex usage request failed with HTTP \(response.status)")
            }

            let payload = try JSONDecoder().decode(RateLimitStatusPayload.self, from: response.body)
            guard let usage = Self.usage(from: payload, now: now) else {
                return Self.failure("No Codex usage data returned")
            }
            return ProviderPartial(provider: .codex,
                                   usage: usage,
                                   usageError: nil,
                                   cost: Self.unavailableCost())
        } catch let error as CredentialAccessError {
            return Self.failure(error.userMessage)
        } catch {
            return Self.failure("Codex usage unreadable (\(type(of: error)))")
        }
    }

    private static func request(credential: CodexCredentialAccess) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func usage(from payload: RateLimitStatusPayload, now: Date) -> ProviderUsage? {
        guard let rateLimit = payload.rateLimit else { return nil }
        let windows = [rateLimit.primaryWindow, rateLimit.secondaryWindow]
            .enumerated()
            .compactMap { window(from: $1, position: $0) }
        guard !windows.isEmpty else { return nil }

        return ProviderUsage(
            provider: .codex,
            windows: windows,
            accountEmail: payload.email,
            planName: payload.planType,
            creditsRemaining: parseCredits(payload.credits?.balance),
            exactMonthlyCap: nil,
            statusIndicator: nil,
            updatedAt: now,
            resetCount: payload.rateLimitResetCredits?.availableCount
        )
    }

    private static func window(from raw: RawCodexRateLimitWindow?, position: Int) -> RateWindow? {
        guard let raw,
              let usedPercent = raw.usedPercent,
              let seconds = raw.limitWindowSeconds,
              seconds.isFinite,
              seconds > 0 else { return nil }
        let minutes = max(1, Int(seconds / 60))
        return RateWindow(
            label: EngineMapper.windowLabel(provider: .codex, position: position, windowMinutes: minutes),
            period: RateWindow.Period(windowMinutes: minutes),
            windowMinutes: minutes,
            usedPercent: clampPercent(usedPercent),
            resetsAt: raw.resetAt.map(Date.init(timeIntervalSince1970:)),
            resetDescription: nil
        )
    }

    private static func parseCredits(_ value: String?) -> Double? {
        guard let value, let parsed = Double(value), parsed.isFinite, parsed >= 0 else { return nil }
        return parsed
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func unavailableCost() -> ProviderCost {
        .unavailable(.codex, reason: "Native Codex cost is unavailable.")
    }

    private static func failure(_ message: String) -> ProviderPartial {
        ProviderPartial(provider: .codex,
                        usage: nil,
                        usageError: message,
                        cost: .unavailable(.codex, reason: message))
    }
}
