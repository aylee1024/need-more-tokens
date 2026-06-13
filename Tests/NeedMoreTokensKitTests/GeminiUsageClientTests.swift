import Foundation
import Testing
@testable import NeedMoreTokensKit

private enum GeminiClientFixture {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static let loadProject = """
    {
      "cloudaicompanionProject": "projects/cloud-ai-companion-123",
      "future": {
        "ignored": true
      }
    }
    """

    static let quota = """
    {
      "buckets": [
        {
          "modelId": "gemini-2.5-pro",
          "tokenType": "tokens",
          "remainingAmount": "1000",
          "remainingFraction": 0.25,
          "resetTime": "2026-06-13T00:00:00Z"
        },
        {
          "modelId": "gemini-2.5-flash",
          "tokenType": "tokens",
          "remainingAmount": "500",
          "remainingFraction": 0.8,
          "resetTime": "2026-06-13T00:00:00Z"
        },
        {
          "modelId": "gemini-2.5-pro",
          "tokenType": "requests",
          "remainingAmount": "10",
          "remainingFraction": 0.1,
          "resetTime": "2026-06-13T00:00:00Z"
        }
      ]
    }
    """

    static let singleQuota = """
    {
      "buckets": [
        {
          "modelId": "gemini-2.5-pro",
          "tokenType": "tokens",
          "remainingAmount": "1000",
          "remainingFraction": 0.25,
          "resetTime": "2026-06-13T00:00:00Z"
        }
      ]
    }
    """

    static func store(geminiJSON: String = geminiOAuth(accessToken: "gemini-token")) throws -> (CredentialStore, URL) {
        try credentialStore(codexJSON: #"{"tokens":{"access_token":"codex-token"}}"#, geminiJSON: geminiJSON)
    }

    static func geminiOAuth(accessToken: String) -> String {
        """
        {
          "access_token": "\(accessToken)",
          "token_type": "Bearer",
          "expiry_date": 1800000000000
        }
        """
    }
}

@Suite("Gemini native usage client")
struct GeminiUsageClientTests {
    @Test func mapsBucketsAndSendsTwoCapturedRequests() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.loadProject),
            .json(GeminiClientFixture.quota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        let usage = try #require(partial.usage)
        #expect(partial.usageError == nil)
        #expect(usage.provider == .gemini)
        #expect(usage.planName == nil)
        #expect(usage.windows.map(\.period) == [.daily, .daily])
        #expect(usage.windows.map(\.label) == ["gemini-2.5-pro", "gemini-2.5-flash"])
        #expect(usage.windows[0].usedPercent == 90)
        #expect(abs(usage.windows[1].usedPercent - 20) < 0.0001)
        #expect(partial.cost.isAvailable == false)

        let requests = await http.recordedRequests()
        #expect(requests.count == 2)
        let load = requests[0]
        #expect(load.url?.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        #expect(load.method == "POST")
        #expect(load.headers["Authorization"] == "Bearer gemini-token")
        #expect(load.headers["Content-Type"] == "application/json")
        let loadBody = try jsonObject(from: load.body)
        #expect((loadBody["metadata"] as? [String: Any])?["userAgent"] as? String == "NeedMoreTokens")

        let quota = requests[1]
        #expect(quota.url?.absoluteString == "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")
        #expect(quota.method == "POST")
        #expect(quota.headers["Authorization"] == "Bearer gemini-token")
        #expect(quota.headers["Content-Type"] == "application/json")
        let quotaBody = try jsonObject(from: quota.body)
        #expect(quotaBody["project"] as? String == "projects/cloud-ai-companion-123")
        #expect(quotaBody["userAgent"] as? String == "NeedMoreTokens")
    }

    @Test func missingProjectStillRetrievesQuotaWithoutProjectKey() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(#"{}"#),
            .json(GeminiClientFixture.singleQuota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        let usage = try #require(partial.usage)
        #expect(usage.windows.count == 1)
        let requests = await http.recordedRequests()
        let quotaBody = try jsonObject(from: requests[1].body)
        #expect(quotaBody["project"] == nil)
        #expect(quotaBody["userAgent"] as? String == "NeedMoreTokens")
    }

    @Test func non200BecomesUsageError() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.loadProject),
            .json(#"{}"#, status: 403),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("HTTP 403") == true)
        #expect(partial.cost.isAvailable == false)
    }

    @Test func malformedBodyBecomesUsageError() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.loadProject),
            HTTPResponse(status: 200, body: Data("{".utf8), headers: [:]),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("Gemini usage unreadable") == true)
    }

    @Test func missingCredentialBecomesUsageErrorWithoutHTTP() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: #"{"token_type":"Bearer"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(GeminiClientFixture.loadProject)])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("access token missing") == true)
        #expect(await http.recordedRequests().isEmpty)
    }
}
