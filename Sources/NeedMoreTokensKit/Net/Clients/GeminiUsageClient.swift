import Foundation

public struct GeminiUsageClient: Sendable {
    private static let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let retrieveQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

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
            // loadCodeAssist is best-effort: if it errors (HTTP/decode), proceed
            // with no project and let retrieveUserQuota resolve or degrade — a
            // transient project lookup must not kill the whole Gemini read.
            let project = try? await loadProject(credential: credential)
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
        } catch {
            return Self.failure("Gemini usage unreadable (\(type(of: error)))")
        }
    }

    private func loadProject(credential: GeminiCredentialAccess) async throws -> String? {
        let response = try await httpClient.send(try Self.loadCodeAssistRequest(credential: credential), timeout: timeout)
        guard response.status == 200 else {
            throw GeminiClientError.http("Gemini Code Assist project request failed with HTTP \(response.status)")
        }
        let payload = try JSONDecoder().decode(RawGeminiLoadCodeAssistPayload.self, from: response.body)
        guard let project = payload.cloudaicompanionProject, !project.isEmpty else { return nil }
        return project
    }

    private static func loadCodeAssistRequest(credential: GeminiCredentialAccess) throws -> URLRequest {
        var request = URLRequest(url: loadCodeAssistURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "userAgent": "NeedMoreTokens",
            ],
        ])
        return request
    }

    private static func retrieveQuotaRequest(credential: GeminiCredentialAccess, project: String?) throws -> URLRequest {
        var request = URLRequest(url: retrieveQuotaURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["userAgent": "NeedMoreTokens"]
        if let project, !project.isEmpty {
            body["project"] = project
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func usage(from payload: RawGeminiQuotaPayload, now: Date) -> ProviderUsage? {
        let windows = windows(from: payload.buckets ?? [])
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

    private static func windows(from buckets: [RawGeminiQuotaBucket]) -> [RateWindow] {
        var orderedModelIDs: [String] = []
        var selectedBuckets: [String: RawGeminiQuotaBucket] = [:]

        for bucket in buckets {
            guard let modelID = bucket.modelID, !modelID.isEmpty else { continue }
            if selectedBuckets[modelID] == nil {
                orderedModelIDs.append(modelID)
                selectedBuckets[modelID] = bucket
                continue
            }
            if let current = selectedBuckets[modelID],
               remainingFraction(bucket) < remainingFraction(current) {
                selectedBuckets[modelID] = bucket
            }
        }

        return orderedModelIDs.compactMap { modelID in
            guard let bucket = selectedBuckets[modelID],
                  let remaining = bucket.remainingFraction,
                  remaining.isFinite else { return nil }
            return RateWindow(
                label: modelID,
                period: .daily,
                windowMinutes: 1_440,
                usedPercent: clampPercent((1 - remaining) * 100),
                resetsAt: EngineMapper.parseDate(bucket.resetTime),
                resetDescription: nil
            )
        }
    }

    private static func remainingFraction(_ bucket: RawGeminiQuotaBucket) -> Double {
        guard let value = bucket.remainingFraction, value.isFinite else { return Double.greatestFiniteMagnitude }
        return value
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

private enum GeminiClientError: Error, CustomStringConvertible {
    case http(String)

    var description: String {
        switch self {
        case .http(let message): message
        }
    }
}
