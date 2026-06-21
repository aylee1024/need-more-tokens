import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Gemini token refresher")
struct GeminiTokenRefresherTests {
    private let config = GeminiOAuthClientConfig(clientID: "test-client-id", clientSecret: "test-secret")

    @Test func exchangesRefreshTokenForAccessTokenViaGoogleTokenEndpoint() async throws {
        let http = StubHTTPClient(responses: [.json(#"{"access_token":"fresh-token","expires_in":3599,"token_type":"Bearer"}"#)])

        let token = try await GeminiTokenRefresher(httpClient: http, clientConfig: config)
            .refreshedAccessToken(refreshToken: "1//rt-value")

        #expect(token == "fresh-token")
        let requests = await http.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(requests[0].method == "POST")
        #expect(requests[0].headers["Content-Type"] == "application/x-www-form-urlencoded")
        let body = String(data: requests[0].body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("client_id=test-client-id"))
        // refresh token is form-encoded ("/" -> %2F) so request bodies stay well-formed
        #expect(body.contains("refresh_token=1%2F%2Frt-value"))
    }

    @Test func missingClientConfigThrowsWithoutHTTP() async {
        let http = StubHTTPClient(responses: [])
        await #expect(throws: GeminiRefreshError.self) {
            _ = try await GeminiTokenRefresher(httpClient: http, clientConfig: nil).refreshedAccessToken(refreshToken: "1//rt")
        }
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test func non200StatusThrows() async {
        let http = StubHTTPClient(responses: [.json(#"{"error":"invalid_grant"}"#, status: 400)])
        await #expect(throws: GeminiRefreshError.self) {
            _ = try await GeminiTokenRefresher(httpClient: http, clientConfig: config).refreshedAccessToken(refreshToken: "1//rt")
        }
    }

    @Test func missingAccessTokenInResponseThrows() async {
        let http = StubHTTPClient(responses: [.json(#"{"expires_in":3599,"token_type":"Bearer"}"#)])
        await #expect(throws: GeminiRefreshError.self) {
            _ = try await GeminiTokenRefresher(httpClient: http, clientConfig: config).refreshedAccessToken(refreshToken: "1//rt")
        }
    }

    @Test func loadReturnsNilWhenFileAbsent() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nmt-absent-\(UUID().uuidString).json")
        #expect(GeminiOAuthClientConfig.load(from: url) == nil)
    }

    @Test func loadReadsClientConfigFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nmt-cfg-\(UUID().uuidString).json")
        try Data(#"{"client_id":"abc","client_secret":"xyz"}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = try #require(GeminiOAuthClientConfig.load(from: url))
        #expect(cfg.clientID == "abc")
        #expect(cfg.clientSecret == "xyz")
        // holds a secret → must be redacted in its description
        #expect(!String(describing: cfg).contains("xyz"))
    }
}
