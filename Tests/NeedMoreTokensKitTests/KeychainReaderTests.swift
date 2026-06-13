import Foundation
import Security
import Testing
@testable import NeedMoreTokensKit

private struct StubKeychainReader: KeychainReading {
    let data: Data?
    let expectedService: String
    let expectedAccount: String?

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        #expect(service == expectedService)
        #expect(account == expectedAccount)
        return data
    }
}

@Suite("Keychain reader")
struct KeychainReaderTests {
    @Test func productionQueryUsesExactClaudeServiceAccountAndNoFuzzyAttributes() {
        let query = KeychainQueryBuilder.genericPasswordQuery(
            service: ClaudeCredentialLoader.defaultService,
            account: ClaudeCredentialLoader.defaultAccount
        )

        let expectedKeys: Set<String> = [
            kSecClass as String,
            kSecAttrService as String,
            kSecAttrAccount as String,
            kSecReturnData as String,
            kSecMatchLimit as String,
        ]
        #expect(Set(query.keys) == expectedKeys)
        #expect(stringValue(query, kSecClass) == kSecClassGenericPassword as String)
        #expect(stringValue(query, kSecAttrService) == "Claude Code-credentials")
        #expect(stringValue(query, kSecAttrAccount) == "andrewlee")
        #expect(boolValue(query, kSecReturnData) == true)
        #expect(stringValue(query, kSecMatchLimit) == kSecMatchLimitOne as String)
        #expect(stringValue(query, kSecMatchLimit) != kSecMatchLimitAll as String)
    }

    @Test func nilAccountQueryOmitsAccountWithoutAddingFuzzyAttributes() {
        let query = KeychainQueryBuilder.genericPasswordQuery(service: "exact-service", account: nil)

        let expectedKeys: Set<String> = [
            kSecClass as String,
            kSecAttrService as String,
            kSecReturnData as String,
            kSecMatchLimit as String,
        ]
        #expect(Set(query.keys) == expectedKeys)
        #expect(stringValue(query, kSecAttrService) == "exact-service")
        #expect(query[kSecAttrAccount as String] == nil)
        #expect(stringValue(query, kSecMatchLimit) == kSecMatchLimitOne as String)
    }

    @Test func claudeLoaderUsesExactDefaultKeychainIdentityAndIsolatesMCP() throws {
        let blob = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-loader-token",
            "expiresAt": 1800000000000,
            "scopes": ["user:profile"],
            "subscriptionType": "max"
          },
          "mcpOAuth": {
            "accessToken": "mcp-loader-token-must-not-surface"
          }
        }
        """
        let reader = StubKeychainReader(
            data: Data(blob.utf8),
            expectedService: "Claude Code-credentials",
            expectedAccount: "andrewlee"
        )

        let access = try ClaudeCredentialLoader(keychainReader: reader)
            .load(now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(access.accessToken == "sk-ant-oat01-loader-token")
        #expect(access.subscriptionType == "max")
        #expect(try #require(access.scopes) == ["user:profile"])
        #expect(String(describing: access).contains("mcp-loader-token-must-not-surface") == false)
    }

    @Test func claudeLoaderMissingKeychainItemSurfacesActionableError() {
        let reader = StubKeychainReader(
            data: nil,
            expectedService: "Claude Code-credentials",
            expectedAccount: "andrewlee"
        )

        do {
            _ = try ClaudeCredentialLoader(keychainReader: reader).load()
            Issue.record("expected missing credential error")
        } catch let error as CredentialAccessError {
            #expect(error.userMessage.contains("run the CLI to re-auth"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private func stringValue(_ query: [String: Any], _ key: CFString) -> String? {
        query[key as String] as? String
    }

    private func boolValue(_ query: [String: Any], _ key: CFString) -> Bool? {
        query[key as String] as? Bool
    }
}
