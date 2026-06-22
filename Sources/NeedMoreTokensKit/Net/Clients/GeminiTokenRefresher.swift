import Foundation

/// The OAuth client (id + secret) used to refresh a Gemini access token. NMT deliberately
/// does NOT ship these values: they are read at runtime from a local, gitignored file
/// (`~/.config/needmoretokens/gemini-oauth.json`) so no OAuth secret lives in the public
/// repo. Must be **agy's (Antigravity's) own OAuth client** — the client the Keychain token
/// (`gemini/antigravity`) was issued under. (gemini-cli's public client does NOT work: its
/// tokens are rejected with HTTP 403 by the Code Assist quota API — verified on-machine — so
/// gemini-cli is unused here.) Obtain agy's client id+secret by capturing agy's refresh
/// request. If the file is absent or wrong, Gemini falls back to "expired — run agy".
public struct GeminiOAuthClientConfig: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/needmoretokens/gemini-oauth.json")
    }

    /// Loads the client config from `url`, or nil if the file is missing/malformed/empty.
    public static func load(from url: URL = defaultURL) -> GeminiOAuthClientConfig? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let id = raw.clientID, !id.isEmpty,
              let secret = raw.clientSecret, !secret.isEmpty,
              CredentialStore.hasNoControlCharacters(id), CredentialStore.hasNoControlCharacters(secret) else {
            return nil
        }
        return GeminiOAuthClientConfig(clientID: id, clientSecret: secret)
    }

    public var description: String { "GeminiOAuthClientConfig(clientID: <redacted>, clientSecret: <redacted>)" }
    public var debugDescription: String { description }

    private struct Raw: Decodable {
        let clientID: String?
        let clientSecret: String?
        private enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
        }
    }
}

/// Exchanges a long-lived Gemini OAuth refresh token for a fresh access token, in-memory.
///
/// NMT reads the Keychain READ-ONLY. Gemini's access token lives ~1 hour and `agy` only
/// refreshes it when it runs, so between `agy` invocations the cached token expires and the
/// card would otherwise show "expired". This mints a fresh access token from the stored
/// refresh token so Gemini stays live — without a codexbar/agy dependency and WITHOUT writing
/// back to Antigravity's Keychain item (the new token is used only for the current fetch).
///
/// The OAuth client id/secret are NOT embedded; they come from a local config (see
/// `GeminiOAuthClientConfig`). When no config is present the refresh is skipped and Gemini
/// falls back to surfacing "expired".
public struct GeminiTokenRefresher: Sendable {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private let httpClient: any HTTPClient
    private let timeout: TimeInterval
    private let clientConfig: GeminiOAuthClientConfig?

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(),
                timeout: TimeInterval = 30,
                clientConfig: GeminiOAuthClientConfig? = GeminiOAuthClientConfig.load()) {
        self.httpClient = httpClient
        self.timeout = timeout
        self.clientConfig = clientConfig
    }

    /// A freshly minted access token plus how long it is valid, so the caller can cache it
    /// and only refresh again near expiry (instead of on every fetch).
    public struct RefreshedToken: Sendable, Equatable {
        public let accessToken: String
        /// Seconds until the access token expires, if the server reported `expires_in`.
        public let expiresIn: TimeInterval?
        public init(accessToken: String, expiresIn: TimeInterval?) {
            self.accessToken = accessToken
            self.expiresIn = expiresIn
        }
    }

    public func refreshedToken(refreshToken: String) async throws -> RefreshedToken {
        guard let config = clientConfig else { throw GeminiRefreshError.clientConfigMissing }
        let response = try await httpClient.send(Self.request(refreshToken: refreshToken, config: config), timeout: timeout)
        guard response.status == 200 else {
            throw GeminiRefreshError.http(status: response.status)
        }
        let payload = try JSONDecoder().decode(RefreshResponse.self, from: response.body)
        guard let token = payload.accessToken, !token.isEmpty,
              CredentialStore.hasNoControlCharacters(token) else {
            throw GeminiRefreshError.noAccessToken
        }
        return RefreshedToken(accessToken: token, expiresIn: payload.expiresIn)
    }

    public func refreshedAccessToken(refreshToken: String) async throws -> String {
        try await refreshedToken(refreshToken: refreshToken).accessToken
    }

    static func request(refreshToken: String, config: GeminiOAuthClientConfig) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            ("client_id", config.clientID),
            ("client_secret", config.clientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ]
        let body = fields
            .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }

    /// Percent-encode for application/x-www-form-urlencoded (RFC 3986 unreserved set).
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String?
        let expiresIn: TimeInterval?
        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }
}

public enum GeminiRefreshError: Error, Sendable, Equatable, CustomStringConvertible {
    case clientConfigMissing
    case http(status: Int)
    case noAccessToken

    public var description: String {
        switch self {
        case .clientConfigMissing: "no local OAuth client configured"
        case .http(let status): "token refresh failed with HTTP \(status)"
        case .noAccessToken: "token refresh returned no access token"
        }
    }
}
