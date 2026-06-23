import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Claude token refresher")
struct ClaudeTokenRefresherTests {
    @Test func returnsRotatedPairAndPostsCorrectBody() async throws {
        let http = StubHTTPClient(responses: [.json(#"{"access_token":"a2","refresh_token":"r2","expires_in":28800}"#)])
        let refreshed = try await ClaudeTokenRefresher(httpClient: http).refreshed(refreshToken: "r1", clientID: "cid")

        #expect(refreshed.accessToken == "a2")
        #expect(refreshed.refreshToken == "r2")   // the rotated token the caller must persist
        #expect(refreshed.expiresIn == 28_800)
        let reqs = await http.recordedRequests()
        #expect(reqs.count == 1)
        #expect(reqs[0].url?.absoluteString == "https://api.anthropic.com/v1/oauth/token")
        #expect(reqs[0].method == "POST")
        let body = try JSONSerialization.jsonObject(with: reqs[0].body ?? Data()) as? [String: Any]
        #expect(body?["grant_type"] as? String == "refresh_token")
        #expect(body?["refresh_token"] as? String == "r1")
        #expect(body?["client_id"] as? String == "cid")
    }

    @Test func non200Throws() async {
        let http = StubHTTPClient(responses: [.json(#"{"error":"invalid_grant"}"#, status: 400)])
        await #expect(throws: ClaudeRefreshError.self) {
            _ = try await ClaudeTokenRefresher(httpClient: http).refreshed(refreshToken: "x", clientID: "c")
        }
    }

    @Test func missingRotatedRefreshTokenThrows() async {
        // Anthropic rotates: a 200 WITHOUT a new refresh_token would silently break the next
        // refresh, so it must fail loudly rather than persist a stale token.
        let http = StubHTTPClient(responses: [.json(#"{"access_token":"a","expires_in":28800}"#)])
        await #expect(throws: ClaudeRefreshError.self) {
            _ = try await ClaudeTokenRefresher(httpClient: http).refreshed(refreshToken: "x", clientID: "c")
        }
    }
}
