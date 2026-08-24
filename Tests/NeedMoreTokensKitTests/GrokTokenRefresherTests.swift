import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Grok token refresher")
struct GrokTokenRefresherTests {
    @Test func exchangesRefreshTokenAtAuthXAI() async throws {
        let http = StubHTTPClient(responses: [
            .json(#"{"access_token":"fresh-grok","expires_in":21600,"token_type":"Bearer"}"#)
        ])

        let refreshed = try await GrokTokenRefresher(httpClient: http)
            .refreshed(refreshToken: "rt/value", clientID: "client-1")

        #expect(refreshed.accessToken == "fresh-grok")
        #expect(refreshed.expiresIn == 21_600)
        #expect(refreshed.refreshToken == nil)
        let requests = await http.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == "https://auth.x.ai/oauth2/token")
        #expect(requests[0].method == "POST")
        #expect(requests[0].headers["Content-Type"] == "application/x-www-form-urlencoded")
        let body = String(data: requests[0].body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("client_id=client-1"))
        #expect(body.contains("refresh_token=rt%2Fvalue"))
        #expect(!body.contains("client_secret"))
    }

    @Test func persistsRotatedRefreshTokenWhenIdPReturnsOne() async throws {
        let http = StubHTTPClient(responses: [
            .json(#"{"access_token":"a2","refresh_token":"rt2","expires_in":21600}"#)
        ])
        let refreshed = try await GrokTokenRefresher(httpClient: http)
            .refreshed(refreshToken: "rt1", clientID: "client-1")
        #expect(refreshed.refreshToken == "rt2")
    }

    @Test func non200StatusThrows() async {
        let http = StubHTTPClient(responses: [.json(#"{"error":"invalid_grant"}"#, status: 400)])
        await #expect(throws: GrokRefreshError.self) {
            _ = try await GrokTokenRefresher(httpClient: http)
                .refreshed(refreshToken: "rt", clientID: "client-1")
        }
    }

    @Test func missingAccessTokenThrows() async {
        let http = StubHTTPClient(responses: [.json(#"{"expires_in":21600}"#)])
        await #expect(throws: GrokRefreshError.self) {
            _ = try await GrokTokenRefresher(httpClient: http)
                .refreshed(refreshToken: "rt", clientID: "client-1")
        }
    }
}
