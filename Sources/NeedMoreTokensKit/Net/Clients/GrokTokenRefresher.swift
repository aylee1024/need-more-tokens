import Foundation

/// Exchanges the Grok CLI's OIDC refresh token for a new access token at
/// `auth.x.ai`. Access tokens last 6 hours; NMT is a background meter and must
/// refresh on its own or the Grok card goes blank between `grok` sessions.
///
/// The CLI is a public PKCE client (`token_endpoint_auth_methods_supported`
/// includes `none`), so this POST has `client_id` and no `client_secret`.
/// If the IdP rotates the refresh token, the new one is returned so the caller
/// can write it back to `~/.grok/auth.json` (grok CLI adopts a sibling write).
public struct GrokTokenRefresher: Sendable {
    static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

    private let httpClient: any HTTPClient
    private let timeout: TimeInterval

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 30) {
        self.httpClient = httpClient
        self.timeout = timeout
    }

    public struct Refreshed: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: TimeInterval?
    }

    public func refreshed(refreshToken: String, clientID: String) async throws -> Refreshed {
        let response = try await httpClient.send(
            Self.request(refreshToken: refreshToken, clientID: clientID), timeout: timeout)
        guard response.status == 200 else {
            throw GrokRefreshError.http(status: response.status)
        }
        let payload = try JSONDecoder().decode(RefreshResponse.self, from: response.body)
        guard let access = payload.accessToken, !access.isEmpty,
              CredentialStore.hasNoControlCharacters(access) else {
            throw GrokRefreshError.noAccessToken
        }
        if let rotated = payload.refreshToken, !rotated.isEmpty {
            guard CredentialStore.hasNoControlCharacters(rotated) else {
                throw GrokRefreshError.noAccessToken
            }
            return Refreshed(accessToken: access, refreshToken: rotated, expiresIn: payload.expiresIn)
        }
        return Refreshed(accessToken: access, refreshToken: nil, expiresIn: payload.expiresIn)
    }

    static func request(refreshToken: String, clientID: String) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("grok-cli", forHTTPHeaderField: "User-Agent")
        let fields = [
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ]
        request.httpBody = Data(fields
            .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
            .joined(separator: "&").utf8)
        return request
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: TimeInterval?
        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }
}

public enum GrokRefreshError: Error, Sendable, Equatable, CustomStringConvertible {
    case http(status: Int)
    case noAccessToken

    public var description: String {
        switch self {
        case .http(let status): "Grok token refresh failed with HTTP \(status)"
        case .noAccessToken: "Grok token refresh returned no access token"
        }
    }
}
