import Foundation
import Testing
@testable import NeedMoreTokensKit

private enum GeminiClientFixture {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static let loadProject = """
    {
      "cloudaicompanionProject": "parabolic-zepplin-pw532",
      "future": {
        "ignored": true
      }
    }
    """

    static let quota = """
    {
      "groups": [
        {
          "displayName": "Gemini Models",
          "description": "Models within this group: Gemini Flash, Gemini Pro",
          "buckets": [
            {
              "bucketId": "gemini-weekly",
              "displayName": "Weekly Limit",
              "window": "weekly",
              "resetTime": "2026-06-25T23:03:46Z",
              "description": "...",
              "remainingFraction": 0.9849711
            },
            {
              "bucketId": "gemini-5h",
              "displayName": "Five Hour Limit",
              "window": "5h",
              "resetTime": "2026-06-19T04:03:46Z",
              "description": "...",
              "remainingFraction": 0.96553755
            }
          ]
        },
        {
          "displayName": "Claude and GPT models",
          "buckets": [
            {
              "bucketId": "3p-weekly",
              "displayName": "Weekly Limit",
              "window": "weekly",
              "resetTime": "2026-06-25T23:03:46Z",
              "description": "...",
              "remainingFraction": 0.10
            },
            {
              "bucketId": "3p-5h",
              "displayName": "Five Hour Limit",
              "window": "5h",
              "resetTime": "2026-06-19T04:03:46Z",
              "description": "...",
              "remainingFraction": 0.20
            }
          ]
        }
      ],
      "description": "..."
    }
    """

    static let fallbackQuota = """
    {
      "groups": [
        {
          "displayName": "Renamed Gemini Models",
          "buckets": [
            {
              "bucketId": "gemini-5h",
              "displayName": "Five Hour Limit",
              "window": "5h",
              "remainingFraction": 0.5
            },
            {
              "bucketId": "3p-5h",
              "displayName": "Five Hour Limit",
              "window": "5h",
              "remainingFraction": 0.1
            }
          ]
        }
      ]
    }
    """

    static func store(geminiJSON: String = antigravityCredential(accessToken: "gemini-token")) throws -> (CredentialStore, URL) {
        try credentialStore(codexJSON: #"{"tokens":{"access_token":"codex-token"}}"#, geminiJSON: geminiJSON)
    }

    static func antigravityCredential(accessToken: String, expiry: String = "2030-01-01T00:00:00Z") -> String {
        """
        {
          "token": {
            "access_token": "\(accessToken)",
            "token_type": "Bearer",
            "refresh_token": "1//refresh",
            "expiry": "\(expiry)"
          },
          "auth_method": "consumer"
        }
        """
    }

    /// An expired Gemini credential (past expiry), optionally with a refresh token.
    static func expiredCredential(refreshToken: Bool) -> String {
        let rt = refreshToken ? "\"refresh_token\": \"1//refresh\"," : ""
        return """
        {
          "token": {
            "access_token": "stale-token",
            "token_type": "Bearer",
            \(rt)
            "expiry": "2020-01-01T00:00:00Z"
          },
          "auth_method": "consumer"
        }
        """
    }

    static let refreshResponse = #"{"access_token":"refreshed-token","expires_in":3599,"token_type":"Bearer"}"#

    /// A refresher with a stub OAuth client config + the shared stub HTTP, so refresh tests
    /// are deterministic instead of depending on a local ~/.config file.
    static func refresher(_ http: StubHTTPClient) -> GeminiTokenRefresher {
        GeminiTokenRefresher(httpClient: http, clientConfig: GeminiOAuthClientConfig(clientID: "test-id", clientSecret: "test-secret"))
    }

    static func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
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
        #expect(usage.windows.count == 2)
        #expect(usage.windows.map(\.period) == [.fiveHour, .weekly])
        #expect(usage.windows.map(\.windowMinutes) == [300, 10_080])
        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.windows.allSatisfy { $0.resetDescription == nil })
        #expect(abs(usage.windows[0].usedPercent - 3.446245) < 0.00001)
        #expect(abs(usage.windows[1].usedPercent - 1.50289) < 0.00001)
        #expect(usage.windows[0].resetsAt == GeminiClientFixture.date("2026-06-19T04:03:46Z"))
        #expect(usage.windows[1].resetsAt == GeminiClientFixture.date("2026-06-25T23:03:46Z"))
        #expect(usage.windows.allSatisfy { !$0.label.contains("3p") })
        #expect(partial.cost.isAvailable == false)

        let requests = await http.recordedRequests()
        #expect(requests.count == 2)
        let load = requests[0]
        #expect(load.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        #expect(load.method == "POST")
        #expect(load.headers["Authorization"] == "Bearer gemini-token")
        #expect(load.headers["Content-Type"] == "application/json")
        let loadBody = try jsonObject(from: load.body)
        #expect((loadBody["metadata"] as? [String: Any])?["ideType"] as? String == "ANTIGRAVITY")

        let quota = requests[1]
        #expect(quota.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
        #expect(quota.method == "POST")
        #expect(quota.headers["Authorization"] == "Bearer gemini-token")
        #expect(quota.headers["Content-Type"] == "application/json")
        #expect(quota.headers["User-Agent"] == "antigravity/cli/1.0.9 darwin/arm64")
        let quotaBody = try jsonObject(from: quota.body)
        #expect(quotaBody["project"] as? String == "parabolic-zepplin-pw532")
        #expect(Set(quotaBody.keys) == Set(["project"]))
    }

    @Test func missingProjectBecomesUsageErrorWithoutQuotaRequest() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(#"{}"#),
            .json(GeminiClientFixture.quota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("Gemini usage unreadable") == true)
        let requests = await http.recordedRequests()
        #expect(requests.count == 1)
    }

    @Test func fallsBackToGeminiBucketIDsWhenGroupDisplayNameChanges() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.loadProject),
            .json(GeminiClientFixture.fallbackQuota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        let usage = try #require(partial.usage)
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "5-hour")
        #expect(usage.windows[0].usedPercent == 50)
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

    @Test func refreshesExpiredTokenThenUsesNewTokenForQuota() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.refreshResponse),  // OAuth refresh exchange
            .json(GeminiClientFixture.loadProject),
            .json(GeminiClientFixture.quota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http, refresher: GeminiClientFixture.refresher(http))
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usageError == nil)
        #expect(partial.usage != nil)
        let requests = await http.recordedRequests()
        #expect(requests.count == 3)
        // First call is the refresh; subsequent calls must carry the REFRESHED token.
        #expect(requests[0].url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(requests[0].method == "POST")
        #expect(requests[1].headers["Authorization"] == "Bearer refreshed-token")
        #expect(requests[2].headers["Authorization"] == "Bearer refreshed-token")
    }

    @Test func expiredTokenWithoutLocalOAuthConfigFallsBackToExpiredWithoutHTTP() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [])
        // No local OAuth client configured → auto-refresh is opt-in, so the card falls back
        // to today's "expired" state and never attempts the refresh call.
        let refresher = GeminiTokenRefresher(httpClient: http, clientConfig: nil)

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http, refresher: refresher)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("expired") == true)
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test func expiredTokenWithoutRefreshTokenSurfacesReauthWithoutHTTP() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: false))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(GeminiClientFixture.loadProject)])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("expired") == true)
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test func failedRefreshSurfacesReauthAfterOnlyTheRefreshCall() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(#"{"error":"invalid_grant"}"#, status: 400),  // refresh rejected
        ])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http, refresher: GeminiClientFixture.refresher(http))
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("refresh failed") == true)
        #expect(await http.recordedRequests().count == 1)
    }

    @Test func missingCredentialBecomesUsageErrorWithoutHTTP() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: #"{"token":{"token_type":"Bearer","expiry":"2030-01-01T00:00:00Z"},"auth_method":"consumer"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(GeminiClientFixture.loadProject)])

        let partial = await GeminiUsageClient(credentialStore: store, httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("access token missing") == true)
        #expect(await http.recordedRequests().isEmpty)
    }
}
