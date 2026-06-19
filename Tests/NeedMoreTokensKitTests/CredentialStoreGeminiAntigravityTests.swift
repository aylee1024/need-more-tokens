import Foundation
import Testing
@testable import NeedMoreTokensKit

private struct GeminiStoreStubKeychainReader: KeychainReading {
    let data: Data?

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        #expect(service == "gemini")
        #expect(account == "antigravity")
        return data
    }
}

@Suite("CredentialStore Gemini Antigravity credentials")
struct CredentialStoreGeminiAntigravityTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func loadGeminiAccessDecodesGoKeyringBase64Token() throws {
        let store = CredentialStore(
            geminiKeychainReader: GeminiStoreStubKeychainReader(
                data: keychainData(accessToken: "ya29.TEST", expiry: "2030-01-01T00:00:00Z")
            )
        )

        let access = try store.loadGeminiAccess(now: now)

        #expect(access.accessToken == "ya29.TEST")
        #expect(access.tokenType == "Bearer")
        #expect(access.scope == nil)
    }

    @Test func loadGeminiAccessThrowsExpiredForExpiredAntigravityToken() {
        let store = CredentialStore(
            geminiKeychainReader: GeminiStoreStubKeychainReader(
                data: keychainData(accessToken: "ya29.TEST", expiry: "2023-11-14T22:13:10Z")
            )
        )

        do {
            _ = try store.loadGeminiAccess(now: now)
            Issue.record("expected expired Gemini credential")
        } catch let error as CredentialAccessError {
            #expect(error == .expired(provider: .gemini))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func loadGeminiAccessTrimsTrailingControlCharsFromKeychainValue() throws {
        // go-keyring can store a value with a trailing newline/NUL; strict base64
        // would reject it and make a valid token unreadable. The store must trim.
        let valid = keychainData(accessToken: "ya29.TRIMMED", expiry: "2030-01-01T00:00:00Z")
        let withTrailingJunk = valid + Data([0x0A, 0x00]) // "\n\0"
        let store = CredentialStore(
            geminiKeychainReader: GeminiStoreStubKeychainReader(data: withTrailingJunk)
        )

        let access = try store.loadGeminiAccess(now: now)

        #expect(access.accessToken == "ya29.TRIMMED")
    }

    @Test func loadCodexAccessThrowsMissingCredentialWhenFileAbsent() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nmt-missing-\(UUID().uuidString)/auth.json")
        let store = CredentialStore(
            codexAuthURL: missing,
            geminiKeychainReader: GeminiStoreStubKeychainReader(data: nil)
        )

        do {
            _ = try store.loadCodexAccess(now: now)
            Issue.record("expected missing Codex credential")
        } catch let error as CredentialAccessError {
            #expect(error == .missingCredential(
                provider: .codex,
                message: "Codex credentials not found — run the CLI to re-auth"
            ))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private func keychainData(accessToken: String, expiry: String) -> Data {
        let json = """
        {
          "token": {
            "access_token": "\(accessToken)",
            "token_type": "Bearer",
            "refresh_token": "1//refresh",
            "expiry": "\(expiry)"
          },
          "auth_method": "consumer"
        }
        """
        let encoded = Data(json.utf8).base64EncodedString()
        return Data("go-keyring-base64:\(encoded)".utf8)
    }
}
