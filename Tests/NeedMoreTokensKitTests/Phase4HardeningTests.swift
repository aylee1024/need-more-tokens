import Foundation
import Testing
@testable import NeedMoreTokensKit

/// An HTTPClient whose error description embeds a secret — proves the clients'
/// generic catch never copies error VALUE (only its type) into usageError.
private struct LeakyError: Error, CustomStringConvertible {
    let description: String
}
private struct ThrowingHTTPClient: HTTPClient {
    let error: Error
    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponse {
        throw error
    }
}

@Suite("Phase 4 hardening")
struct Phase4HardeningTests {
    /// Antigravity's quota endpoint requires the project returned by loadCodeAssist,
    /// so a bootstrap failure degrades to a ProviderPartial failure without quota IO.
    @Test func geminiFailsWithoutQuotaRequestWhenLoadCodeAssistFails() async throws {
        let (store, dir) = try credentialStore(
            codexJSON: #"{"tokens":{"access_token":"c"}}"#,
            geminiJSON: #"{"token":{"access_token":"g","token_type":"Bearer","expiry":"2030-01-01T00:00:00Z"},"auth_method":"consumer"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(results: [
            .response(HTTPResponse(status: 403, body: Data(), headers: [:])),          // loadCodeAssist fails
            .response(.json(#"{"groups":[]}"#)),
        ])
        let usage = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http).fetch()
        #expect(usage.usage == nil)
        #expect(usage.usageError?.contains("Gemini usage unreadable") == true)
        #expect(await http.recordedRequests().count == 1)
    }

    /// Both Codex reviewers' HIGH: the generic catch must not interpolate the raw
    /// error value (which an injected client could load with token material).
    @Test func codexErrorMessageNeverContainsTokenMaterial() async throws {
        let secret = "sk-ant-oat01-SUPERSECRET-Bearer-leak"
        let (store, dir) = try credentialStore(
            codexJSON: #"{"tokens":{"access_token":"c","account_id":"a"}}"#,
            geminiJSON: #"{"access_token":"g"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = ThrowingHTTPClient(error: LeakyError(description: "Authorization: Bearer \(secret)"))
        let partial = await OpenAICodexClient(credentialStore: store, httpClient: http).fetch()
        #expect(partial.usageError != nil)
        #expect(!(partial.usageError ?? "").contains(secret))
        #expect(!(partial.cost.unavailableReason ?? "").contains(secret))
    }
}
