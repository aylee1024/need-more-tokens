import Foundation
import Testing
@testable import NeedMoreTokensKit

/// Guards for the two review-panel hardening fixes on the credentials layer.
@Suite("Credential hardening")
struct CredentialHardeningTests {
    /// Gemini HIGH: the Claude keychain account must track the live OS user, not a
    /// hardcoded name — otherwise the app finds no credentials for any other user.
    @Test func claudeLoaderDefaultAccountTracksCurrentUser() {
        #expect(ClaudeCredentialLoader.defaultAccount == NSUserName())
    }

    /// Opus LOW: the *CredentialAccess structs carry a live token; their string
    /// descriptions must redact it (both description and debugDescription).
    @Test func credentialAccessDescriptionsRedactToken() {
        let secret = "sk-ant-oat01-TOPSECRET-должно-redact"
        let claude = ClaudeCredentialAccess(accessToken: secret, subscriptionType: "max", scopes: ["user:profile"], expiresAt: nil)
        let codex = CodexCredentialAccess(accessToken: secret, accountID: "acct-1")
        let gemini = GeminiCredentialAccess(accessToken: secret, tokenType: "Bearer", scope: "x")
        for value in [String(describing: claude), String(reflecting: claude),
                      String(describing: codex), String(reflecting: codex),
                      String(describing: gemini), String(reflecting: gemini)] {
            #expect(!value.contains(secret))
            #expect(value.contains("<redacted>"))
        }
        // Non-secret metadata stays visible.
        #expect(String(describing: claude).contains("max"))
        #expect(String(describing: codex).contains("acct-1"))
    }
}
