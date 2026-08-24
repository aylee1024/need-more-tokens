import Foundation

/// Reads the xAI Grok CLI's OIDC credential from `~/.grok/auth.json` — a FILE (mode 600),
/// like Codex's `~/.codex/auth.json`, so NMT reads it with no Keychain and no prompt.
///
/// The file maps `"<issuer>::<client_id>" -> { key, refresh_token, expires_at, ... }` where
/// `key` is the JWT access token. Access tokens last 6 hours; NMT refreshes via
/// `GrokTokenRefresher` and writes the new access token (and a rotated refresh token,
/// if the IdP sent one) back here so grok CLI's sibling-refresh path can adopt it.
/// An absent/unreadable file still surfaces a clean re-auth message.
public struct GrokCredentialLoader: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    private let url: URL
    public init(url: URL = GrokCredentialLoader.defaultURL) { self.url = url }

    public struct Credential: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String?
        public let clientID: String?
        public let accountKey: String
        public let expiresAt: Date?
        public let isAccessTokenExpired: Bool
        public init(accessToken: String, refreshToken: String? = nil, clientID: String? = nil,
                    accountKey: String = "", expiresAt: Date?, isAccessTokenExpired: Bool = false) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.clientID = clientID
            self.accountKey = accountKey
            self.expiresAt = expiresAt
            self.isAccessTokenExpired = isAccessTokenExpired
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
              let match = object.first(where: { $0.value.key?.isEmpty == false }) ?? object.first,
              let token = match.value.key, !token.isEmpty,
              CredentialStore.hasNoControlCharacters(token) else {
            throw CredentialAccessError.invalidCredential(
                provider: .grok, message: "Grok credentials unreadable — run grok to sign in")
        }
        let entry = match.value
        let expiry = CredentialExpiry.parseISO8601Date(entry.expiresAt)
        let expired = expiry.map { $0 <= now.addingTimeInterval(skew) } ?? false
        let refresh = entry.refreshToken.flatMap { token in
            token.isEmpty || !CredentialStore.hasNoControlCharacters(token) ? nil : token
        }
        let clientID = Self.clientID(from: entry.oidcClientID, accountKey: match.key)
        return Credential(accessToken: token, refreshToken: refresh, clientID: clientID,
                          accountKey: match.key, expiresAt: expiry, isAccessTokenExpired: expired)
    }

    /// Writes a refreshed access token (and rotated refresh token, if any) back into the
    /// same account object, preserving unknown keys so grok CLI's other fields survive.
    /// Best-effort: a write failure leaves the in-memory token usable for this fetch.
    public func persistRefreshed(accountKey: String, accessToken: String,
                                 refreshToken: String?, expiresAt: Date) {
        guard !accountKey.isEmpty,
              let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entry = root[accountKey] as? [String: Any] else { return }
        entry["key"] = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            entry["refresh_token"] = refreshToken
        }
        entry["expires_at"] = Self.iso8601String(expiresAt)
        root[accountKey] = entry
        guard let updated = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return }
        FileManager.default.createFile(atPath: url.path, contents: updated,
                                       attributes: [.posixPermissions: 0o600])
    }

    private static func clientID(from oidcClientID: String?, accountKey: String) -> String? {
        if let oidcClientID, !oidcClientID.isEmpty { return oidcClientID }
        if let idx = accountKey.range(of: "::", options: .backwards) {
            let tail = String(accountKey[idx.upperBound...])
            return tail.isEmpty ? nil : tail
        }
        return nil
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct Entry: Decodable {
        let key: String?
        let expiresAt: String?
        let refreshToken: String?
        let oidcClientID: String?
        private enum CodingKeys: String, CodingKey {
            case key
            case expiresAt = "expires_at"
            case refreshToken = "refresh_token"
            case oidcClientID = "oidc_client_id"
        }
    }
}
