import Foundation
import Testing
@testable import NeedMoreTokensKit

private enum CodexClientFixture {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static let usage = """
    {
      "user_id": "user_123",
      "account_id": "acct_123",
      "email": "andrew@example.com",
      "plan_type": "prolite",
      "rate_limit": {
        "primary_window": {
          "used_percent": 12.5,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 900,
          "reset_at": 1700001800
        },
        "secondary_window": {
          "used_percent": 40,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 300000,
          "reset_at": 1700604800
        }
      },
      "code_review_rate_limit": {
        "primary_window": {
          "used_percent": 1,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 900,
          "reset_at": 1700001800
        }
      },
      "additional_rate_limits": [],
      "credits": {
        "has_credits": true,
        "unlimited": false,
        "overage_limit_reached": false,
        "balance": "1234.5",
        "approx_local_messages": [10, 20],
        "approx_cloud_messages": [3, 5]
      },
      "spend_control": {},
      "rate_limit_reached_type": null,
      "promo": null,
      "referral_beacon": {},
      "rate_limit_reset_credits": {
        "available_count": 1
      }
    }
    """

    static func store(codexJSON: String = codexAuth(accessToken: "codex-token")) throws -> (CredentialStore, URL) {
        try credentialStore(codexJSON: codexJSON, geminiJSON: #"{"access_token":"gemini-token"}"#)
    }

    static func codexAuth(accessToken: String) -> String {
        """
        {
          "tokens": {
            "access_token": "\(accessToken)",
            "account_id": "acct_123"
          }
        }
        """
    }
}

@Suite("OpenAI Codex native client")
struct OpenAICodexClientTests {
    @Test func mapsUsageAndSendsCapturedHeaders() async throws {
        let (store, dir) = try CodexClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(CodexClientFixture.usage)])

        let partial = await OpenAICodexClient(credentialStore: store, httpClient: http)
            .fetch(now: CodexClientFixture.now)

        let usage = try #require(partial.usage)
        #expect(partial.usageError == nil)
        #expect(usage.provider == .codex)
        #expect(usage.windows.map(\.period) == [.fiveHour, .weekly])
        #expect(usage.windows.map(\.windowMinutes) == [300, 10_080])
        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.windows[0].usedPercent == 12.5)
        #expect(usage.windows[1].usedPercent == 40)
        #expect(usage.planName == "prolite")
        #expect(usage.accountEmail == "andrew@example.com")
        #expect(usage.creditsRemaining == 1234.5)
        #expect(usage.resetCount == 1)
        #expect(partial.cost.isAvailable == false)

        let requests = await http.recordedRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.method == "GET")
        #expect(request.headers["Authorization"] == "Bearer codex-token")
        #expect(request.headers["ChatGPT-Account-Id"] == "acct_123")
        #expect(request.headers["Content-Type"] == "application/json")
    }

    @Test func non200BecomesUsageError() async throws {
        let (store, dir) = try CodexClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(#"{}"#, status: 429)])

        let partial = await OpenAICodexClient(credentialStore: store, httpClient: http)
            .fetch(now: CodexClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("HTTP 429") == true)
        #expect(partial.cost.isAvailable == false)
    }

    @Test func malformedBodyBecomesUsageError() async throws {
        let (store, dir) = try CodexClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, body: Data("{".utf8), headers: [:])])

        let partial = await OpenAICodexClient(credentialStore: store, httpClient: http)
            .fetch(now: CodexClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("Codex usage unreadable") == true)
    }

    @Test func missingCredentialBecomesUsageErrorWithoutHTTP() async throws {
        let (store, dir) = try CodexClientFixture.store(codexJSON: #"{"tokens":{"account_id":"acct_123"}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(CodexClientFixture.usage)])

        let partial = await OpenAICodexClient(credentialStore: store, httpClient: http)
            .fetch(now: CodexClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("access token missing") == true)
        #expect(await http.recordedRequests().isEmpty)
    }
}

func credentialStore(codexJSON: String, geminiJSON: String) throws -> (CredentialStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("nmt-native-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let codexURL = dir.appendingPathComponent("codex-auth.json")
    let geminiURL = dir.appendingPathComponent("gemini-oauth.json")
    try Data(codexJSON.utf8).write(to: codexURL)
    try Data(geminiJSON.utf8).write(to: geminiURL)
    return (
        CredentialStore(
            codexAuthURL: codexURL,
            geminiOAuthURL: geminiURL,
            geminiKeychainReader: TestGeminiKeychainReader(data: Data(geminiJSON.utf8))
        ),
        dir
    )
}

struct TestGeminiKeychainReader: KeychainReading {
    let data: Data?

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        #expect(service == "gemini")
        #expect(account == "antigravity")
        return data
    }
}
