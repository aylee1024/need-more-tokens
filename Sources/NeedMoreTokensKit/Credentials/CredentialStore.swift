import Foundation

public struct CredentialStore: Sendable {
    public static var defaultCodexAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    public static var defaultGeminiOAuthURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
    }
    public static let defaultGeminiKeychainService = "gemini"
    public static let defaultGeminiKeychainAccount = "antigravity"

    public let codexAuthURL: URL
    public let geminiOAuthURL: URL
    private let geminiKeychainReader: any KeychainReading
    private let geminiKeychainService: String
    private let geminiKeychainAccount: String?

    public init(codexAuthURL: URL = CredentialStore.defaultCodexAuthURL,
                geminiOAuthURL: URL = CredentialStore.defaultGeminiOAuthURL,
                geminiKeychainReader: any KeychainReading = SystemKeychainReader(),
                geminiKeychainService: String = CredentialStore.defaultGeminiKeychainService,
                geminiKeychainAccount: String? = CredentialStore.defaultGeminiKeychainAccount) {
        self.codexAuthURL = codexAuthURL
        self.geminiOAuthURL = geminiOAuthURL
        self.geminiKeychainReader = geminiKeychainReader
        self.geminiKeychainService = geminiKeychainService
        self.geminiKeychainAccount = geminiKeychainAccount
    }

    static func hasNoControlCharacters(_ token: String) -> Bool {
        token.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    public func loadCodexAuth() throws -> CodexAuth {
        try decode(CodexAuth.self, from: codexAuthURL)
    }

    public func loadGeminiOAuth() throws -> GeminiOAuth {
        try decode(GeminiOAuth.self, from: geminiOAuthURL)
    }

    public func loadCodexAccess(now: Date = Date(),
                                skew: TimeInterval = CredentialExpiry.defaultSkew) throws -> CodexCredentialAccess {
        let auth: CodexAuth
        do {
            auth = try loadCodexAuth()
        } catch {
            // A missing/unreadable ~/.codex/auth.json should drive the re-auth
            // flow, not surface a raw CocoaError to the UI (mirrors the Gemini path).
            throw CredentialAccessError.missingCredential(
                provider: .codex,
                message: "Codex credentials not found — run the CLI to re-auth"
            )
        }
        guard let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty else {
            throw CredentialAccessError.missingAccessToken(provider: .codex)
        }
        guard Self.hasNoControlCharacters(accessToken) else {
            throw CredentialAccessError.invalidCredential(
                provider: .codex,
                message: "Codex token is malformed — run the CLI to re-auth"
            )
        }
        if auth.isAccessTokenKnownExpired(now: now, skew: skew) {
            throw CredentialAccessError.expired(provider: .codex)
        }
        return CodexCredentialAccess(accessToken: accessToken, accountID: auth.tokens?.accountID)
    }

    public func loadGeminiAccess(now: Date = Date(),
                                 skew: TimeInterval = CredentialExpiry.defaultSkew) throws -> GeminiCredentialAccess {
        let credential = try loadGeminiAntigravityCredential()
        guard let accessToken = credential.token?.accessToken, !accessToken.isEmpty else {
            throw CredentialAccessError.missingAccessToken(provider: .gemini)
        }
        guard Self.hasNoControlCharacters(accessToken) else {
            throw CredentialAccessError.invalidCredential(
                provider: .gemini,
                message: "Gemini token is malformed — re-auth in Antigravity or run agy"
            )
        }
        if credential.isAccessTokenKnownExpired(now: now, skew: skew) {
            throw CredentialAccessError.expired(provider: .gemini)
        }
        return GeminiCredentialAccess(accessToken: accessToken, tokenType: credential.token?.tokenType, scope: nil)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func loadGeminiAntigravityCredential() throws -> GeminiAntigravityCredential {
        let data: Data?
        do {
            data = try geminiKeychainReader.readGenericPassword(
                service: geminiKeychainService,
                account: geminiKeychainAccount
            )
        } catch let error as KeychainReadError where error.isAccessNotGranted {
            throw CredentialAccessError.accessNotGranted(provider: .gemini)
        }
        guard let data else {
            throw CredentialAccessError.missingCredential(
                provider: .gemini,
                message: "Gemini credentials not found in Keychain - re-auth in Antigravity or run agy"
            )
        }
        guard let rawValue = String(data: data, encoding: .utf8) else {
            throw CredentialAccessError.invalidCredential(
                provider: .gemini,
                message: "Gemini credentials unreadable - re-auth in Antigravity or run agy"
            )
        }
        let jsonData = try Self.geminiKeychainJSONData(from: rawValue)
        do {
            return try JSONDecoder().decode(GeminiAntigravityCredential.self, from: jsonData)
        } catch {
            throw CredentialAccessError.invalidCredential(
                provider: .gemini,
                message: "Gemini credentials unreadable - re-auth in Antigravity or run agy"
            )
        }
    }

    private static func geminiKeychainJSONData(from rawValue: String) throws -> Data {
        let prefix = "go-keyring-base64:"
        // go-keyring (the Go lib agy uses) can store a value with a trailing NUL
        // or newline; strict base64 decoding would reject it and make a valid
        // token unreadable. Trim whitespace + control chars before decoding.
        let trimmed = rawValue.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        guard trimmed.hasPrefix(prefix) else { return Data(trimmed.utf8) }
        let encoded = String(trimmed.dropFirst(prefix.count))
        guard let decoded = Data(base64Encoded: encoded) else {
            throw CredentialAccessError.invalidCredential(
                provider: .gemini,
                message: "Gemini credentials unreadable - re-auth in Antigravity or run agy"
            )
        }
        return decoded
    }
}

public struct CodexAuth: Decodable, Sendable, Equatable {
    public let authMode: String?
    public let tokens: Tokens?
    public let lastRefresh: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authMode = container.decodeLossy(String.self, forKey: .authMode)
        tokens = container.decodeLossy(Tokens.self, forKey: .tokens)
        lastRefresh = container.decodeLossy(String.self, forKey: .lastRefresh)
    }

    public func isAccessTokenKnownExpired(now: Date = Date(),
                                          skew: TimeInterval = CredentialExpiry.defaultSkew) -> Bool {
        CredentialExpiry.codexAccessTokenKnownExpired(tokens?.accessToken, now: now, skew: skew)
    }

    private enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
        case lastRefresh = "last_refresh"
    }

    public struct Tokens: Decodable, Sendable, Equatable {
        public let accessToken: String?
        public let refreshToken: String?
        public let accountID: String?
        public let idToken: String?

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = container.decodeLossy(String.self, forKey: .accessToken)
            refreshToken = container.decodeLossy(String.self, forKey: .refreshToken)
            accountID = container.decodeLossy(String.self, forKey: .accountID)
            idToken = container.decodeLossy(String.self, forKey: .idToken)
        }

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case accountID = "account_id"
            case idToken = "id_token"
        }
    }
}

public struct GeminiOAuth: Decodable, Sendable, Equatable {
    public let accessToken: String?
    public let refreshToken: String?
    public let tokenType: String?
    public let expiryDate: Double?
    public let scope: String?
    public let idToken: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = container.decodeLossy(String.self, forKey: .accessToken)
        refreshToken = container.decodeLossy(String.self, forKey: .refreshToken)
        tokenType = container.decodeLossy(String.self, forKey: .tokenType)
        expiryDate = container.decodeLossy(Double.self, forKey: .expiryDate)
        scope = container.decodeLossy(String.self, forKey: .scope)
        idToken = container.decodeLossy(String.self, forKey: .idToken)
    }

    public func isAccessTokenKnownExpired(now: Date = Date(),
                                          skew: TimeInterval = CredentialExpiry.defaultSkew) -> Bool {
        CredentialExpiry.millisecondsTimestampKnownExpired(expiryDate, now: now, skew: skew)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiryDate = "expiry_date"
        case scope
        case idToken = "id_token"
    }
}

public struct GeminiAntigravityCredential: Codable, Sendable, Equatable {
    public let token: Token?
    public let authMethod: String?

    public func isAccessTokenKnownExpired(now: Date = Date(),
                                          skew: TimeInterval = CredentialExpiry.defaultSkew) -> Bool {
        CredentialExpiry.iso8601TimestampKnownExpired(token?.expiry, now: now, skew: skew)
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case authMethod = "auth_method"
    }

    public struct Token: Codable, Sendable, Equatable {
        public let accessToken: String?
        public let tokenType: String?
        public let refreshToken: String?
        public let expiry: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case refreshToken = "refresh_token"
            case expiry
        }
    }
}

// Defense-in-depth: the *Access structs already redact, but these raw credential
// containers hold live tokens. Redact them too so an accidental log/interpolation
// of the container can never leak access/refresh/id tokens.
extension CodexAuth: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "CodexAuth(authMode: \(authMode ?? "nil"), tokens: <redacted>, lastRefresh: \(lastRefresh ?? "nil"))" }
    public var debugDescription: String { description }
}

extension GeminiOAuth: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "GeminiOAuth(tokenType: \(tokenType ?? "nil"), scope: \(scope ?? "nil"), accessToken: <redacted>, refreshToken: <redacted>, idToken: <redacted>)" }
    public var debugDescription: String { description }
}

extension GeminiAntigravityCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "GeminiAntigravityCredential(authMethod: \(authMethod ?? "nil"), token: <redacted>)" }
    public var debugDescription: String { description }
}

extension ClaudeCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ClaudeCredential(claudeAiOauth: <redacted>)" }
    public var debugDescription: String { description }
}

public struct ClaudeCredential: Decodable, Sendable, Equatable {
    private let claudeAiOauth: ClaudeAIOAuth?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeAiOauth = container.decodeLossy(ClaudeAIOAuth.self, forKey: .claudeAiOauth)
    }

    public var accessToken: String? {
        claudeAiOauth?.accessToken
    }

    public var metadata: ClaudeCredentialMetadata? {
        guard claudeAiOauth != nil else { return nil }
        return ClaudeCredentialMetadata(subscriptionType: claudeAiOauth?.subscriptionType,
                                        scopes: claudeAiOauth?.scopes,
                                        expiresAt: claudeAiOauth?.expiresAt)
    }

    public var access: ClaudeCredentialAccess? {
        guard let accessToken, !accessToken.isEmpty else { return nil }
        return ClaudeCredentialAccess(accessToken: accessToken,
                                      subscriptionType: claudeAiOauth?.subscriptionType,
                                      scopes: claudeAiOauth?.scopes,
                                      expiresAt: claudeAiOauth?.expiresAt)
    }

    public func isAccessTokenKnownExpired(now: Date = Date(),
                                          skew: TimeInterval = CredentialExpiry.defaultSkew) -> Bool {
        CredentialExpiry.millisecondsTimestampKnownExpired(claudeAiOauth?.expiresAt, now: now, skew: skew)
    }

    private enum CodingKeys: String, CodingKey {
        case claudeAiOauth
    }

    private struct ClaudeAIOAuth: Decodable, Sendable, Equatable {
        let accessToken: String?
        let expiresAt: Double?
        let scopes: [String]?
        let subscriptionType: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = container.decodeLossy(String.self, forKey: .accessToken)
            expiresAt = container.decodeLossy(Double.self, forKey: .expiresAt)
            scopes = container.decodeLossy([String].self, forKey: .scopes)
            subscriptionType = container.decodeLossy(String.self, forKey: .subscriptionType)
        }

        private enum CodingKeys: String, CodingKey {
            case accessToken
            case expiresAt
            case scopes
            case subscriptionType
        }
    }
}

public struct ClaudeCredentialMetadata: Sendable, Equatable {
    public let subscriptionType: String?
    public let scopes: [String]?
    public let expiresAt: Double?

    public init(subscriptionType: String?, scopes: [String]?, expiresAt: Double?) {
        self.subscriptionType = subscriptionType
        self.scopes = scopes
        self.expiresAt = expiresAt
    }
}

public struct CodexCredentialAccess: Sendable, Equatable {
    public let accessToken: String
    public let accountID: String?

    public init(accessToken: String, accountID: String?) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

public struct GeminiCredentialAccess: Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String?
    public let scope: String?

    public init(accessToken: String, tokenType: String?, scope: String?) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.scope = scope
    }
}

public struct ClaudeCredentialAccess: Sendable, Equatable {
    public let accessToken: String
    public let subscriptionType: String?
    public let scopes: [String]?
    public let expiresAt: Double?

    public init(accessToken: String, subscriptionType: String?, scopes: [String]?, expiresAt: Double?) {
        self.accessToken = accessToken
        self.subscriptionType = subscriptionType
        self.scopes = scopes
        self.expiresAt = expiresAt
    }
}

// Redacted descriptions: these structs carry a live first-party access token. The
// synthesized reflection-based description would print it verbatim, so any future
// caller that logs one (e.g. a client error path) would leak it. Redact the token
// in both `description` and `debugDescription`; non-secret metadata stays visible.
extension CodexCredentialAccess: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "CodexCredentialAccess(accessToken: <redacted>, accountID: \(accountID ?? "nil"))" }
    public var debugDescription: String { description }
}

extension GeminiCredentialAccess: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "GeminiCredentialAccess(accessToken: <redacted>, tokenType: \(tokenType ?? "nil"))" }
    public var debugDescription: String { description }
}

extension ClaudeCredentialAccess: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ClaudeCredentialAccess(accessToken: <redacted>, subscriptionType: \(subscriptionType ?? "nil"))" }
    public var debugDescription: String { description }
}

public enum CredentialAccessError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingCredential(provider: Provider, message: String)
    case missingAccessToken(provider: Provider)
    case invalidCredential(provider: Provider, message: String)
    case expired(provider: Provider)
    /// The provider's token lives in a Keychain item NMT has no ACL grant for, and
    /// background prompts are disabled, so the read failed without a dialog. The user
    /// grants access once via Settings ▸ Enable native access.
    case accessNotGranted(provider: Provider)

    public var userMessage: String {
        switch self {
        case .missingCredential(_, let message):
            message
        case .missingAccessToken(let provider):
            "\(provider.displayName) access token missing - run the CLI to re-auth"
        case .invalidCredential(_, let message):
            message
        case .expired(let provider):
            if provider == .gemini {
                "\(provider.displayName) token expired — re-auth in Antigravity or run agy"
            } else {
                "\(provider.displayName) token expired — run the CLI to re-auth"
            }
        case .accessNotGranted(let provider):
            "\(provider.displayName) needs Keychain access — Settings ▸ Enable native access"
        }
    }

    public var description: String {
        userMessage
    }
}

public enum CredentialExpiry {
    public static let defaultSkew: TimeInterval = 60

    public static func codexAccessTokenKnownExpired(_ accessToken: String?,
                                                    now: Date = Date(),
                                                    skew: TimeInterval = defaultSkew) -> Bool {
        guard let accessToken, let exp = jwtExpiration(accessToken) else { return false }
        return secondsTimestampKnownExpired(exp, now: now, skew: skew)
    }

    public static func millisecondsTimestampKnownExpired(_ milliseconds: Double?,
                                                         now: Date = Date(),
                                                         skew: TimeInterval = defaultSkew) -> Bool {
        guard let milliseconds, milliseconds.isFinite else { return false }
        return secondsTimestampKnownExpired(milliseconds / 1_000, now: now, skew: skew)
    }

    public static func iso8601TimestampKnownExpired(_ string: String?,
                                                    now: Date = Date(),
                                                    skew: TimeInterval = defaultSkew) -> Bool {
        guard let date = parseISO8601Date(string) else { return false }
        return secondsTimestampKnownExpired(date.timeIntervalSince1970, now: now, skew: skew)
    }

    private static func secondsTimestampKnownExpired(_ seconds: TimeInterval,
                                                     now: Date,
                                                     skew: TimeInterval) -> Bool {
        guard seconds.isFinite else { return false }
        return seconds <= now.addingTimeInterval(skew).timeIntervalSince1970
    }

    private static func parseISO8601Date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private static func jwtExpiration(_ accessToken: String) -> TimeInterval? {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1,
              let payload = Data(base64URLEncoded: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        if let exp = dictionary["exp"] as? Double {
            return exp
        }
        if let exp = dictionary["exp"] as? Int {
            return TimeInterval(exp)
        }
        if let exp = dictionary["exp"] as? String {
            return TimeInterval(exp)
        }
        return nil
    }
}

private extension KeyedDecodingContainer {
    func decodeLossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
