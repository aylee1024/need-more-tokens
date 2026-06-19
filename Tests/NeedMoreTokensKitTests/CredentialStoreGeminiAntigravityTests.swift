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
