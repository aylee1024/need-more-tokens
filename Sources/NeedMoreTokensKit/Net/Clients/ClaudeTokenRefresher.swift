import Foundation

/// Refreshes NMT's OWN Claude OAuth token against Anthropic's token endpoint. Unlike Gemini
/// (whose refresh token is reusable), Anthropic ROTATES Claude's refresh token: every refresh
/// returns a NEW refresh token and invalidates the old one. So this returns the new refresh
/// token too, and the caller MUST persist it (see `ClaudeOAuthStore`) — otherwise the next
/// refresh fails. Verified end-to-end on-machine.
public struct ClaudeTokenRefresher: Sendable {
    static let tokenURL = URL(string: "https://api.anthropic.com/v1/oauth/token")!
    /// Mirror the Claude CLI's client header so the endpoint behaves identically.
    private static let userAgent = "claude-cli/2.1.185 (external, cli)"

    private let httpClient: any HTTPClient
    private let timeout: TimeInterval

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 30) {
        self.httpClient = httpClient
        self.timeout = timeout
    }

    public struct Refreshed: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String   // ROTATED — caller must persist this
        public let expiresIn: TimeInterval?
    }

    public func refreshed(refreshToken: String, clientID: String) async throws -> Refreshed {
        let response = try await httpClient.send(Self.request(refreshToken: refreshToken, clientID: clientID), timeout: timeout)
        guard response.status == 200 else {
            throw ClaudeRefreshError.http(status: response.status)
        }
        let payload = try JSONDecoder().decode(RefreshResponse.self, from: response.body)
        guard let access = payload.accessToken, !access.isEmpty,
              CredentialStore.hasNoControlCharacters(access),
              let refresh = payload.refreshToken, !refresh.isEmpty,
              CredentialStore.hasNoControlCharacters(refresh) else {
            throw ClaudeRefreshError.missingToken
        }
        return Refreshed(accessToken: access, refreshToken: refresh, expiresIn: payload.expiresIn)
    }

    static func request(refreshToken: String, clientID: String) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
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

public enum ClaudeRefreshError: Error, Sendable, Equatable, CustomStringConvertible {
    case http(status: Int)
    case missingToken

    public var description: String {
        switch self {
        case .http(let status): "Claude token refresh failed with HTTP \(status)"
        case .missingToken: "Claude token refresh returned no token"
        }
    }
}
