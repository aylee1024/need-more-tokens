import Foundation

/// Reads the xAI Grok CLI's OIDC credential from `~/.grok/auth.json` — a FILE (mode 600),
/// like Codex's `~/.codex/auth.json`, so NMT reads it with no Keychain and no prompt.
///
/// The file maps `"<issuer>::<client_id>" -> { key, refresh_token, expires_at, ... }` where
/// `key` is the JWT access token. NMT only READS the access token (to query the subscription);
/// it never refreshes — the Grok CLI keeps the token fresh, and refreshing here might rotate
/// it (mirrors the Claude rule). An expired/absent token surfaces a clean re-auth message.
public struct GrokCredentialLoader: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    private let url: URL
    public init(url: URL = GrokCredentialLoader.defaultURL) { self.url = url }

    public struct Credential: Sendable, Equatable {
        public let accessToken: String
        public let expiresAt: Date?
        public init(accessToken: String, expiresAt: Date?) {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
        }
    }

    public func load(now: Date = Date(),
                     skew: TimeInterval = CredentialExpiry.defaultSkew) throws -> Credential {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CredentialAccessError.missingCredential(
                provider: .grok, message: "Grok credentials not found — run grok to sign in")
        }
        guard let object = try? JSONDecoder().decode([String: Entry].self, from: data),
              // The file usually has one account; prefer an entry with a non-empty access token.
              let entry = object.values.first(where: { ($0.key?.isEmpty == false) }) ?? object.values.first,
              let token = entry.key, !token.isEmpty,
              CredentialStore.hasNoControlCharacters(token) else {
            throw CredentialAccessError.invalidCredential(
                provider: .grok, message: "Grok credentials unreadable — run grok to sign in")
        }
        let expiry = CredentialExpiry.parseISO8601Date(entry.expiresAt)
        if let expiry, expiry <= now.addingTimeInterval(skew) {
            throw CredentialAccessError.expired(provider: .grok)
        }
        return Credential(accessToken: token, expiresAt: expiry)
    }

    private struct Entry: Decodable {
        let key: String?
        let expiresAt: String?
        private enum CodingKeys: String, CodingKey {
            case key
            case expiresAt = "expires_at"
        }
    }
}
