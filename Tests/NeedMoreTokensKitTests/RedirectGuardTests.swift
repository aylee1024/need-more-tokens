import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Redirect guard")
struct RedirectGuardTests {
    @Test func crossOriginRedirectStripsSensitiveHeaders() throws {
        let originalURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let rewritten = try #require(RedirectGuard.rewrite(
            originalURL: originalURL,
            newRequest: redirectRequest(to: "https://attacker.example/capture")
        ))

        #expect(rewritten.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(rewritten.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
        #expect(rewritten.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(rewritten.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func sameOriginRedirectPreservesHeaders() throws {
        let originalURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let rewritten = try #require(RedirectGuard.rewrite(
            originalURL: originalURL,
            newRequest: redirectRequest(to: "https://chatgpt.com/backend-api/next")
        ))

        #expect(rewritten.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(rewritten.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct_123")
        #expect(rewritten.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(rewritten.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func nonHTTPSRedirectIsRefused() {
        let originalURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let rewritten = RedirectGuard.rewrite(
            originalURL: originalURL,
            newRequest: redirectRequest(to: "http://chatgpt.com/backend-api/next")
        )

        #expect(rewritten == nil)
    }

    private func redirectRequest(to url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        request.setValue("acct_123", forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
