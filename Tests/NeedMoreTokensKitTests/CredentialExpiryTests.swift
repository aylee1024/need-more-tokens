import Foundation
import Testing
@testable import NeedMoreTokensKit

private enum JWTFixture {
    static func token(exp: TimeInterval?) -> String {
        let header = base64URL(#"{"alg":"none"}"#)
        let payload: String
        if let exp {
            payload = #"{"exp":\#(Int(exp))}"#
        } else {
            payload = #"{"sub":"no-exp"}"#
        }
        return "\(header).\(base64URL(payload)).signature"
    }

    static func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct ExpiryStubKeychainReader: KeychainReading {
    let data: Data?

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        data
    }
}

@Suite("Credential expiry")
struct CredentialExpiryTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func codexExpiryDetectsExpiredValidAndUnparseableJWTs() {
        let expired = JWTFixture.token(exp: now.timeIntervalSince1970 - 10)
        let nearExpiry = JWTFixture.token(exp: now.timeIntervalSince1970 + 30)
        let valid = JWTFixture.token(exp: now.timeIntervalSince1970 + 3_600)
        let withoutExp = JWTFixture.token(exp: nil)

        #expect(CredentialExpiry.codexAccessTokenKnownExpired(expired, now: now) == true)
        #expect(CredentialExpiry.codexAccessTokenKnownExpired(nearExpiry, now: now) == true)
        #expect(CredentialExpiry.codexAccessTokenKnownExpired(valid, now: now) == false)
        #expect(CredentialExpiry.codexAccessTokenKnownExpired("not-a-jwt", now: now) == false)
        #expect(CredentialExpiry.codexAccessTokenKnownExpired(withoutExp, now: now) == false)
    }

    @Test func geminiExpiryDetectsExpiredValidAndUnparseableDates() throws {
        let expired = try decode(GeminiOAuth.self, from: gemini(expiry: now.addingTimeInterval(-10).timeIntervalSince1970 * 1_000))
        let nearExpiry = try decode(GeminiOAuth.self, from: gemini(expiry: now.addingTimeInterval(30).timeIntervalSince1970 * 1_000))
        let valid = try decode(GeminiOAuth.self, from: gemini(expiry: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000))
        let unparseable = try decode(GeminiOAuth.self, from: #"{"access_token":"token","expiry_date":"not-a-number"}"#)

        #expect(expired.isAccessTokenKnownExpired(now: now) == true)
        #expect(nearExpiry.isAccessTokenKnownExpired(now: now) == true)
        #expect(valid.isAccessTokenKnownExpired(now: now) == false)
        #expect(unparseable.isAccessTokenKnownExpired(now: now) == false)
        #expect(CredentialExpiry.millisecondsTimestampKnownExpired(.nan, now: now) == false)
    }

    @Test func geminiAntigravityExpiryDetectsExpiredValidAndUnparseableDates() throws {
        let expired = try decode(GeminiAntigravityCredential.self, from: geminiAntigravity(expiry: iso(now.addingTimeInterval(-10))))
        let nearExpiry = try decode(GeminiAntigravityCredential.self, from: geminiAntigravity(expiry: iso(now.addingTimeInterval(30))))
        let valid = try decode(GeminiAntigravityCredential.self, from: geminiAntigravity(expiry: iso(now.addingTimeInterval(3_600))))
        let unparseable = try decode(GeminiAntigravityCredential.self, from: geminiAntigravity(expiry: "not-a-date"))

        #expect(expired.isAccessTokenKnownExpired(now: now) == true)
        #expect(nearExpiry.isAccessTokenKnownExpired(now: now) == true)
        #expect(valid.isAccessTokenKnownExpired(now: now) == false)
        #expect(unparseable.isAccessTokenKnownExpired(now: now) == false)
        #expect(CredentialExpiry.iso8601TimestampKnownExpired(nil, now: now) == false)
    }

    @Test func claudeExpiryDetectsExpiredValidAndUnparseableDates() throws {
        let expired = try decode(ClaudeCredential.self, from: claude(expiresAt: now.addingTimeInterval(-10).timeIntervalSince1970 * 1_000))
        let nearExpiry = try decode(ClaudeCredential.self, from: claude(expiresAt: now.addingTimeInterval(30).timeIntervalSince1970 * 1_000))
        let valid = try decode(ClaudeCredential.self, from: claude(expiresAt: now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000))
        let unparseable = try decode(ClaudeCredential.self, from: """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-token",
            "expiresAt": "not-a-number"
          }
        }
        """)

        #expect(expired.isAccessTokenKnownExpired(now: now) == true)
        #expect(nearExpiry.isAccessTokenKnownExpired(now: now) == true)
        #expect(valid.isAccessTokenKnownExpired(now: now) == false)
        #expect(unparseable.isAccessTokenKnownExpired(now: now) == false)
    }

    @Test func fileCredentialLoadersSurfaceExpiredErrors() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nmt-credentials-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let codexURL = try write(
            """
            {
              "tokens": {
                "access_token": "\(JWTFixture.token(exp: now.timeIntervalSince1970 - 10))",
                "account_id": "acct_123"
              }
            }
            """,
            named: "codex-auth.json",
            in: dir
        )
        let geminiURL = try write(
            """
            {
              "access_token": "gemini-token",
              "expiry_date": \(now.addingTimeInterval(-10).timeIntervalSince1970 * 1_000)
            }
            """,
            named: "gemini-oauth.json",
            in: dir
        )
        let store = CredentialStore(
            codexAuthURL: codexURL,
            geminiOAuthURL: geminiURL,
            geminiKeychainReader: ExpiryStubKeychainReader(
                data: Data(geminiAntigravity(expiry: iso(now.addingTimeInterval(-10))).utf8)
            )
        )

        expectExpired(.codex) {
            _ = try store.loadCodexAccess(now: now)
        }
        expectExpired(.gemini) {
            _ = try store.loadGeminiAccess(now: now)
        }
    }

    @Test func claudeLoaderSurfacesExpiredErrorWithoutWritingBack() {
        let reader = ExpiryStubKeychainReader(data: Data(claude(expiresAt: now.addingTimeInterval(-10).timeIntervalSince1970 * 1_000).utf8))

        expectExpired(.claude) {
            _ = try ClaudeCredentialLoader(keychainReader: reader).load(now: now)
        }
    }

    private func gemini(expiry: Double) -> String {
        """
        {
          "access_token": "gemini-token",
          "expiry_date": \(expiry)
        }
        """
    }

    private func geminiAntigravity(expiry: String) -> String {
        """
        {
          "token": {
            "access_token": "gemini-token",
            "token_type": "Bearer",
            "expiry": "\(expiry)"
          },
          "auth_method": "consumer"
        }
        """
    }

    private func claude(expiresAt: Double) -> String {
        """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-token",
            "expiresAt": \(expiresAt),
            "scopes": ["user:profile"],
            "subscriptionType": "max"
          }
        }
        """
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func write(_ contents: String, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func expectExpired(_ provider: Provider, body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected expired \(provider.displayName) credential")
        } catch let error as CredentialAccessError {
            #expect(error == .expired(provider: provider))
            if provider == .gemini {
                #expect(error.userMessage == "\(provider.displayName) token expired — re-auth in Antigravity or run agy")
            } else {
                #expect(error.userMessage == "\(provider.displayName) token expired — run the CLI to re-auth")
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
