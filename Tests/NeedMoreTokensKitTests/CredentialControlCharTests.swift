import Foundation
import Testing
@testable import NeedMoreTokensKit

private struct ControlCharStubKeychainReader: KeychainReading {
    let data: Data?

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        data
    }
}

@Suite("Credential control characters")
struct CredentialControlCharTests {
    @Test func codexAccessTokenWithControlCharacterIsInvalid() throws {
        let (store, dir) = try store(
            codexJSON: #"{"tokens":{"access_token":"codex-token\n","account_id":"acct_123"}}"#,
            geminiJSON: #"{"access_token":"gemini-token"}"#
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        expectInvalidCredential(.codex) {
            _ = try store.loadCodexAccess()
        }
    }

    @Test func codexCleanAccessTokenLoads() throws {
        let (store, dir) = try store(
            codexJSON: #"{"tokens":{"access_token":"codex-token","account_id":"acct_123"}}"#,
            geminiJSON: #"{"access_token":"gemini-token"}"#
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let access = try store.loadCodexAccess()
        #expect(access.accessToken == "codex-token")
        #expect(access.accountID == "acct_123")
    }

    @Test func geminiAccessTokenWithControlCharacterIsInvalid() throws {
        let (store, dir) = try store(
            codexJSON: #"{"tokens":{"access_token":"codex-token"}}"#,
            geminiJSON: geminiAntigravityCredential(accessToken: #"gemini-token\n"#)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        expectInvalidCredential(.gemini) {
            _ = try store.loadGeminiAccess()
        }
    }

    @Test func geminiCleanAccessTokenLoads() throws {
        let (store, dir) = try store(
            codexJSON: #"{"tokens":{"access_token":"codex-token"}}"#,
            geminiJSON: geminiAntigravityCredential(accessToken: "gemini-token")
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let access = try store.loadGeminiAccess()
        #expect(access.accessToken == "gemini-token")
        #expect(access.tokenType == "Bearer")
    }

    @Test func claudeAccessTokenWithControlCharacterIsInvalid() {
        let reader = ControlCharStubKeychainReader(data: Data(claudeCredential(accessToken: #"sk-ant-oat01-token\n"#).utf8))

        expectInvalidCredential(.claude) {
            _ = try ClaudeCredentialLoader(keychainReader: reader).load()
        }
    }

    @Test func claudeCleanAccessTokenLoads() throws {
        let reader = ControlCharStubKeychainReader(data: Data(claudeCredential(accessToken: "sk-ant-oat01-token").utf8))

        let access = try ClaudeCredentialLoader(keychainReader: reader).load()
        #expect(access.accessToken == "sk-ant-oat01-token")
        #expect(access.subscriptionType == "max")
        #expect(try #require(access.scopes) == ["user:profile"])
    }

    private func store(codexJSON: String, geminiJSON: String) throws -> (CredentialStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nmt-control-char-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let codexURL = dir.appendingPathComponent("codex-auth.json")
        let geminiURL = dir.appendingPathComponent("gemini-oauth.json")
        try Data(codexJSON.utf8).write(to: codexURL)
        try Data(geminiJSON.utf8).write(to: geminiURL)
        return (
            CredentialStore(
                codexAuthURL: codexURL,
                geminiOAuthURL: geminiURL,
                geminiKeychainReader: ControlCharStubKeychainReader(data: Data(geminiJSON.utf8))
            ),
            dir
        )
    }

    private func geminiAntigravityCredential(accessToken: String) -> String {
        """
        {
          "token": {
            "access_token": "\(accessToken)",
            "token_type": "Bearer",
            "expiry": "2030-01-01T00:00:00Z"
          },
          "auth_method": "consumer"
        }
        """
    }

    private func claudeCredential(accessToken: String) -> String {
        """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": 1800000000000,
            "scopes": ["user:profile"],
            "subscriptionType": "max"
          }
        }
        """
    }

    private func expectInvalidCredential(_ provider: Provider, body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected invalid \(provider.displayName) credential")
        } catch let error as CredentialAccessError {
            let message: String
            if provider == .gemini {
                message = "\(provider.displayName) token is malformed — re-auth in Antigravity or run agy"
            } else {
                message = "\(provider.displayName) token is malformed — run the CLI to re-auth"
            }
            #expect(error == .invalidCredential(
                provider: provider,
                message: message
            ))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
