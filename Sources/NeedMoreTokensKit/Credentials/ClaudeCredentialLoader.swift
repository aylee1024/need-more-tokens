import Foundation

public struct ClaudeCredentialLoader: Sendable {
    public static let defaultService = "Claude Code-credentials"
    /// The Claude Code keychain item is stored under the current OS user's short
    /// name (verified: the item's account attribute equals `NSUserName()`). Using
    /// the live username keeps the exact account scoping AND makes the app work for
    /// every user — not just the machine it was developed on.
    public static var defaultAccount: String { NSUserName() }

    private let keychainReader: any KeychainReading
    private let service: String
    private let account: String?

    public init(keychainReader: any KeychainReading = SystemKeychainReader(),
                service: String = ClaudeCredentialLoader.defaultService,
                account: String? = ClaudeCredentialLoader.defaultAccount) {
        self.keychainReader = keychainReader
        self.service = service
        self.account = account
    }

    public func load(now: Date = Date(),
                     skew: TimeInterval = CredentialExpiry.defaultSkew) throws -> ClaudeCredentialAccess {
        let rawData: Data?
        do {
            rawData = try keychainReader.readGenericPassword(service: service, account: account)
        } catch let error as KeychainReadError where error.isAccessNotGranted {
            throw CredentialAccessError.accessNotGranted(provider: .claude)
        }
        guard let data = rawData else {
            throw CredentialAccessError.missingCredential(
                provider: .claude,
                message: "Claude credentials not found in Keychain - run the CLI to re-auth"
            )
        }

        let credential: ClaudeCredential
        do {
            credential = try JSONDecoder().decode(ClaudeCredential.self, from: data)
        } catch {
            throw CredentialAccessError.invalidCredential(
                provider: .claude,
                message: "Claude credentials unreadable - run the CLI to re-auth"
            )
        }

        guard let accessToken = credential.accessToken, !accessToken.isEmpty else {
            throw CredentialAccessError.missingAccessToken(provider: .claude)
        }
        guard CredentialStore.hasNoControlCharacters(accessToken) else {
            throw CredentialAccessError.invalidCredential(
                provider: .claude,
                message: "Claude token is malformed — run the CLI to re-auth"
            )
        }
        if credential.isAccessTokenKnownExpired(now: now, skew: skew) {
            throw CredentialAccessError.expired(provider: .claude)
        }
        let metadata = credential.metadata
        return ClaudeCredentialAccess(accessToken: accessToken,
                                      subscriptionType: metadata?.subscriptionType,
                                      scopes: metadata?.scopes,
                                      expiresAt: metadata?.expiresAt)
    }
}
