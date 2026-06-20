import Foundation
import Security
import Testing
@testable import NeedMoreTokensKit

/// A reader that fails the way an un-granted Keychain item does when background prompts
/// are disabled (see `KeychainInteraction`): it throws a `KeychainReadError` with the
/// given OSStatus rather than returning data.
private struct ThrowingKeychainReader: KeychainReading {
    let status: OSStatus
    func readGenericPassword(service: String, account: String?) throws -> Data? {
        throw KeychainReadError(status: status)
    }
}

@Suite("Keychain access-not-granted mapping")
struct KeychainAccessNotGrantedTests {
    @Test func isAccessNotGrantedRecognizesAuthFailedAndInteractionNotAllowed() {
        #expect(KeychainReadError(status: errSecAuthFailed).isAccessNotGranted)
        #expect(KeychainReadError(status: errSecInteractionNotAllowed).isAccessNotGranted)
        // Not "needs a grant" — these are different failures.
        #expect(!KeychainReadError(status: errSecItemNotFound).isAccessNotGranted)
        #expect(!KeychainReadError(status: errSecSuccess).isAccessNotGranted)
        #expect(!KeychainReadError(status: errSecParam).isAccessNotGranted)
    }

    @Test func accessNotGrantedUserMessageGuidesToSettings() {
        let message = CredentialAccessError.accessNotGranted(provider: .claude).userMessage
        #expect(message.contains("Enable native access"))
        #expect(message.contains(Provider.claude.displayName))
    }

    @Test func claudeLoaderMapsAuthFailedToAccessNotGranted() {
        let loader = ClaudeCredentialLoader(keychainReader: ThrowingKeychainReader(status: errSecAuthFailed))
        do {
            _ = try loader.load()
            Issue.record("expected accessNotGranted")
        } catch let error as CredentialAccessError {
            #expect(error == .accessNotGranted(provider: .claude))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func geminiStoreMapsInteractionNotAllowedToAccessNotGranted() {
        let store = CredentialStore(geminiKeychainReader: ThrowingKeychainReader(status: errSecInteractionNotAllowed))
        do {
            _ = try store.loadGeminiAccess()
            Issue.record("expected accessNotGranted")
        } catch let error as CredentialAccessError {
            #expect(error == .accessNotGranted(provider: .gemini))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func nonAccessKeychainErrorIsNotMisclassifiedAsAccessNotGranted() {
        // A Keychain error that is NOT "needs a grant" must not be swallowed as
        // accessNotGranted — it propagates as a KeychainReadError for honest surfacing.
        let loader = ClaudeCredentialLoader(keychainReader: ThrowingKeychainReader(status: errSecParam))
        do {
            _ = try loader.load()
            Issue.record("expected a thrown error")
        } catch let error as CredentialAccessError {
            Issue.record("should not map to CredentialAccessError: \(error)")
        } catch let error as KeychainReadError {
            #expect(error.status == errSecParam)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
