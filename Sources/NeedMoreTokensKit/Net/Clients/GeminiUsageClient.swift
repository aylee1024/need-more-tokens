import Foundation

public struct GeminiUsageClient: Sendable {
    private static let loadCodeAssistURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let retrieveQuotaURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    // The grouped quota endpoint gates its response on the Antigravity CLI's
    // User-Agent — without it the server returns empty `groups`. Mirror agy.
    private static let antigravityUserAgent = "antigravity/cli/1.0.9 darwin/arm64"

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
            let credential = try credentialStore.loadGeminiAccess(now: now)
            let project = try await loadProject(credential: credential)
            let quotaResponse = try await httpClient.send(try Self.retrieveQuotaRequest(credential: credential, project: project), timeout: timeout)
            guard quotaResponse.status == 200 else {
                return Self.failure("Gemini quota request failed with HTTP \(quotaResponse.status)")
            }

            let payload = try JSONDecoder().decode(RawGeminiQuotaPayload.self, from: quotaResponse.body)
            guard let usage = Self.usage(from: payload, now: now) else {
                return Self.failure("No Gemini quota buckets returned")
            }
            return ProviderPartial(provider: .gemini,
                                   usage: usage,
                                   usageError: nil,
                                   cost: Self.unavailableCost())
        } catch let error as CredentialAccessError {
            return Self.failure(error.userMessage)
        } catch let error as GeminiClientError {
            // Surface the real cause (e.g. the loadCodeAssist HTTP status) instead
            // of the opaque type name, so failures are diagnosable.
            return Self.failure("Gemini usage unreadable: \(error.description)")
        } catch {
            return Self.failure("Gemini usage unreadable (\(type(of: error)))")
        }
    }

    private func loadProject(credential: GeminiCredentialAccess) async throws -> String {
        let response = try await httpClient.send(try Self.loadCodeAssistRequest(credential: credential), timeout: timeout)
        guard response.status == 200 else {
            throw GeminiClientError.http("Gemini Code Assist project request failed with HTTP \(response.status)")
        }
        let payload = try JSONDecoder().decode(RawGeminiLoadCodeAssistPayload.self, from: response.body)
        guard let project = payload.cloudaicompanionProject, !project.isEmpty else {
            throw GeminiClientError.http("Gemini Code Assist project missing")
        }
        return project
    }

    private static func loadCodeAssistRequest(credential: GeminiCredentialAccess) throws -> URLRequest {
        var request = URLRequest(url: loadCodeAssistURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(antigravityUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "ideType": "ANTIGRAVITY",
            ],
        ])
        return request
    }

    private static func retrieveQuotaRequest(credential: GeminiCredentialAccess, project: String) throws -> URLRequest {
        var request = URLRequest(url: retrieveQuotaURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(antigravityUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["project": project])
        return request
    }

    private static func usage(from payload: RawGeminiQuotaPayload, now: Date) -> ProviderUsage? {
        let windows = windows(from: payload)
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

    private static func windows(from payload: RawGeminiQuotaPayload) -> [RateWindow] {
        let groups = payload.groups ?? []
        let geminiGroups = groups.filter { $0.displayName == "Gemini Models" }
        let buckets: [RawGeminiQuotaBucket]
        if geminiGroups.isEmpty {
            buckets = groups
                .flatMap { $0.buckets ?? [] }
                .filter { $0.bucketId?.hasPrefix("gemini-") == true }
        } else {
            buckets = geminiGroups.flatMap { $0.buckets ?? [] }
        }

        return buckets.compactMap { bucket -> RateWindow? in
            guard let remaining = bucket.remainingFraction,
                  remaining.isFinite else { return nil }
            let period = period(for: bucket.window)
            // Match the Claude/Codex card style: terse period label ("5-hour" /
            // "Weekly") and let the UI render "Resets in X" from resetsAt rather
            // than the server's verbose `description` sentence.
            return RateWindow(
                label: period.shortLabel,
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
