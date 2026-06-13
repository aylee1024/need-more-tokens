import Foundation
import Testing
@testable import NeedMoreTokensKit

private enum CredentialFixtures {
    static let codexAuth = """
    {
      "auth_mode": "chatgpt",
      "unknown_top_level": "ignored",
      "tokens": {
        "access_token": "codex-access-token",
        "refresh_token": "rt.1.codex-refresh",
        "account_id": "acct_123",
        "id_token": "codex-id-token",
        "nested_future_key": { "ignored": true }
      },
      "last_refresh": "2026-06-12T12:00:00Z"
    }
    """

    static let geminiOAuth = """
    {
      "access_token": "gemini-access-token",
      "refresh_token": "gemini-refresh-token",
      "token_type": "Bearer",
      "expiry_date": 1800000000000,
      "scope": "https://www.googleapis.com/auth/cloud-platform",
      "id_token": "gemini-id-token",
      "future_google_field": ["ignored"]
    }
    """

    static let claudeBlobWithMCP = """
    {
      "claudeAiOauth": {
        "accessToken": "sk-ant-oat01-claude-token",
        "refreshToken": "claude-refresh-token-not-surfaced",
        "expiresAt": 1800000000000,
        "scopes": ["user:profile", "org:usage"],
        "subscriptionType": "max",
        "rateLimitTier": "tier-not-surfaced",
        "futureClaudeField": "ignored"
      },
      "mcpOAuth": {
        "accessToken": "mcp-secret-token-must-not-surface",
        "refreshToken": "mcp-refresh-token-must-not-surface"
      },
      "futureTopLevel": "ignored"
    }
    """

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

@Suite("Credential decode")
struct CredentialsDecodeTests {
    @Test func decodesCodexAuthWithUnknownKeys() throws {
        let auth = try CredentialFixtures.decode(CodexAuth.self, from: CredentialFixtures.codexAuth)

        #expect(auth.authMode == "chatgpt")
        #expect(auth.tokens?.accessToken == "codex-access-token")
        #expect(auth.tokens?.refreshToken == "rt.1.codex-refresh")
        #expect(auth.tokens?.accountID == "acct_123")
        #expect(auth.tokens?.idToken == "codex-id-token")
        #expect(auth.lastRefresh == "2026-06-12T12:00:00Z")
    }

    @Test func decodesGeminiOAuthWithUnknownKeys() throws {
        let oauth = try CredentialFixtures.decode(GeminiOAuth.self, from: CredentialFixtures.geminiOAuth)

        #expect(oauth.accessToken == "gemini-access-token")
        #expect(oauth.refreshToken == "gemini-refresh-token")
        #expect(oauth.tokenType == "Bearer")
        #expect(oauth.expiryDate == 1_800_000_000_000)
        #expect(oauth.scope == "https://www.googleapis.com/auth/cloud-platform")
        #expect(oauth.idToken == "gemini-id-token")
    }

    @Test func claudeCredentialReturnsOnlyClaudeAiOauthAccessAndMetadata() throws {
        let credential = try CredentialFixtures.decode(ClaudeCredential.self, from: CredentialFixtures.claudeBlobWithMCP)
        let access = try #require(credential.access)

        #expect(access.accessToken == "sk-ant-oat01-claude-token")
        #expect(access.subscriptionType == "max")
        #expect(try #require(access.scopes) == ["user:profile", "org:usage"])
        #expect(access.expiresAt == 1_800_000_000_000)
        #expect(String(describing: access).contains("mcp-secret-token-must-not-surface") == false)
        #expect(String(describing: access).contains("mcp-refresh-token-must-not-surface") == false)

        let exposedLabels = Set(Mirror(reflecting: access).children.compactMap(\.label))
        #expect(exposedLabels == ["accessToken", "subscriptionType", "scopes", "expiresAt"])
    }

    @Test func missingFieldsDecodeToNil() throws {
        let codex = try CredentialFixtures.decode(CodexAuth.self, from: #"{}"#)
        let gemini = try CredentialFixtures.decode(GeminiOAuth.self, from: #"{}"#)
        let claude = try CredentialFixtures.decode(ClaudeCredential.self, from: #"{}"#)

        #expect(codex.tokens == nil)
        #expect(gemini.accessToken == nil)
        #expect(claude.access == nil)
        #expect(claude.metadata == nil)
    }
}
