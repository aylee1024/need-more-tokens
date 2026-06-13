import Foundation
import Testing
@testable import NeedMoreTokensKit

private struct ClientStubKeychainReader: KeychainReading {
    let data: Data?

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        #expect(service == "Claude Code-credentials")
        #expect(account == "andrewlee")
        return data
    }
}

private enum ClaudeClientFixture {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static let credential = """
    {
      "claudeAiOauth": {
        "accessToken": "sk-ant-oat01-claude-token",
        "expiresAt": 1800000000000,
        "scopes": ["user:profile"],
        "subscriptionType": "max"
      },
      "mcpOAuth": {
        "accessToken": "mcp-token-must-not-be-sent"
      }
    }
    """

    static let usage = """
    {
      "five_hour": {
        "utilization": 13,
        "resets_at": "2026-06-12T17:00:00Z"
      },
      "seven_day": {
        "utilization": 40,
        "resets_at": null
      },
      "seven_day_sonnet": {
        "utilization": 1,
        "resets_at": "2026-06-19T17:00:00Z"
      },
      "seven_day_opus": null,
      "extra_usage": {
        "is_enabled": true,
        "monthly_limit": 40,
        "used_credits": 3.5,
        "utilization": 8.75,
        "currency": "USD",
        "disabled_reason": null
      },
      "tangelo": {
        "ignored": true
      }
    }
    """
}

@Suite("Claude native usage client")
struct ClaudeUsageClientTests {
    @Test func mapsUsageAndSendsCapturedHeaders() async throws {
        let http = StubHTTPClient(responses: [.json(ClaudeClientFixture.usage)])
        let reader = ClientStubKeychainReader(data: Data(ClaudeClientFixture.credential.utf8))

        let partial = await ClaudeUsageClient(keychainReader: reader, httpClient: http)
            .fetch(now: ClaudeClientFixture.now)

        let usage = try #require(partial.usage)
        #expect(partial.usageError == nil)
        #expect(usage.provider == .claude)
        #expect(usage.windows.map(\.period) == [.fiveHour, .weekly, .weekly])
        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly", "Weekly · Sonnet"])
        #expect(usage.windows.map(\.usedPercent) == [13, 40, 1])
        #expect(usage.planName == "Claude Max")
        let cap = try #require(usage.exactMonthlyCap)
        #expect(cap.used == 3.5)
        #expect(cap.limit == 40)
        #expect(cap.currencyCode == "USD")
        #expect(cap.periodLabel == "Monthly cap")
        #expect(partial.cost.isAvailable == false)

        let requests = await http.recordedRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.method == "GET")
        #expect(request.headers["Authorization"] == "Bearer sk-ant-oat01-claude-token")
        #expect(request.headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(request.headers["User-Agent"] == "claude-code/2.1.0")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/json")
    }

    @Test func non200BecomesUsageError() async {
        let http = StubHTTPClient(responses: [.json(#"{}"#, status: 401)])
        let reader = ClientStubKeychainReader(data: Data(ClaudeClientFixture.credential.utf8))

        let partial = await ClaudeUsageClient(keychainReader: reader, httpClient: http)
            .fetch(now: ClaudeClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("HTTP 401") == true)
        #expect(partial.cost.isAvailable == false)
    }

    @Test func malformedBodyBecomesUsageError() async {
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, body: Data("{".utf8), headers: [:])])
        let reader = ClientStubKeychainReader(data: Data(ClaudeClientFixture.credential.utf8))

        let partial = await ClaudeUsageClient(keychainReader: reader, httpClient: http)
            .fetch(now: ClaudeClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("Claude usage unreadable") == true)
    }

    @Test func missingCredentialBecomesUsageErrorWithoutHTTP() async {
        let http = StubHTTPClient(responses: [.json(ClaudeClientFixture.usage)])
        let reader = ClientStubKeychainReader(data: nil)

        let partial = await ClaudeUsageClient(keychainReader: reader, httpClient: http)
            .fetch(now: ClaudeClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("Claude credentials not found") == true)
        #expect(await http.recordedRequests().isEmpty)
    }
}
