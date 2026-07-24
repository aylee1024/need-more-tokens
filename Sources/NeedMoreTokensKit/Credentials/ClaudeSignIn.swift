import CryptoKit
import Foundation

/// The one-time Claude sign-in, in-app.
///
/// NMT holds its OWN Claude OAuth token so it never reads Claude Code's Keychain item (that
/// read kept getting evicted — see `ClaudeOAuthStore`). Anthropic caps the grant's absolute
/// lifetime and rotation does NOT extend it, so a perfectly healthy install still needs a
/// fresh sign-in periodically (observed: ~30 days). That makes re-signing-in a NORMAL part of
/// the app, not a repair procedure, so it belongs in the UI rather than in a terminal script.
///
/// The flow is the CLI's: PKCE against the CONSUMER authorize endpoint, which is what grants
/// the full session scope. The platform endpoint caps this client at `user:profile`, and a
/// token with only that scope is 403'd by `/api/oauth/usage` — so the URL below is exact, not
/// interchangeable.
public struct ClaudeSignIn: Sendable {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeEndpoint = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = URL(string: "https://api.anthropic.com/v1/oauth/token")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let scope = "user:inference user:mcp_servers user:profile user:sessions:claude_code"
    private static let userAgent = "claude-cli/2.1.185 (external, cli)"

    private let httpClient: any HTTPClient
    private let timeout: TimeInterval

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 30) {
        self.httpClient = httpClient
        self.timeout = timeout
    }

    /// One sign-in attempt. The verifier is the PKCE secret AND the `state` value, mirroring
    /// the CLI's flow: the authorize URL carries the verifier's SHA-256 as `code_challenge`
    /// and the verifier ITSELF as `state`, so the raw value does reach the browser's address
    /// bar and Anthropic's logs. That costs PKCE some of its value against an observer of the
    /// authorize request, who would still also need the one-time code — which Anthropic shows
    /// only on the approving user's screen. The echo back in `state` is what proves a pasted
    /// code belongs to THIS attempt.
    public struct Session: Sendable, Equatable {
        public let verifier: String
        public let url: URL
    }

    /// Starts an attempt: a fresh 256-bit verifier and the authorize URL to open.
    public static func begin(verifier: String = randomVerifier()) -> Session {
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: authorizeEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier),
        ]
        return Session(verifier: verifier, url: components.url!)
    }

    /// Splits the value Anthropic displays — `<code>#<state>` — tolerating stray whitespace
    /// from the copy. A bare code (no `#`) is accepted and validated against the session's
    /// state instead, so a partial copy still works.
    public static func parse(pasted: String) -> (code: String, state: String)? {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        let state = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (code, state)
    }

    /// True for a string that is a code from THIS attempt, so the sign-in pane can pick one up
    /// off the clipboard without the user typing anything.
    ///
    /// The ONLY real test is that the string's state half equals `expectedState` — this
    /// attempt's 256-bit verifier, which nothing but its own approval page can carry. Shape is
    /// no test at all: "issue-1234#comment-5678" satisfies every structural rule anyone would
    /// write.
    ///
    /// So there are deliberately no charset or minimum-length rules here. Once the state
    /// matches, a stricter filter can only do harm — it cannot exclude junk the state match
    /// would admit, but it CAN reject a genuine code whose format we have not verified,
    /// silently, while the pane still promises to pick the code up. The invariant that matters
    /// is that anything this accepts, `complete` will also accept.
    public static func looksLikeCode(_ candidate: String, expectedState: String) -> Bool {
        guard !expectedState.isEmpty else { return false }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 4096, trimmed.contains("#") else { return false }
        guard let (code, state) = parse(pasted: trimmed) else { return false }
        return state == expectedState && !code.isEmpty
    }

    /// Exchanges the pasted code for a token and returns it ready to store.
    ///
    /// A returned `state` that differs from this session's verifier means the code came from a
    /// different attempt, so it throws rather than spending it. A code pasted with NO state at
    /// all skips that check: the user typed or partially copied it, and the check is redundant
    /// there anyway — PKCE is what binds the code to this app. The server verifies
    /// `code_verifier` against the `code_challenge` registered when the code was minted, so a
    /// code obtained for anyone else's authorize request cannot be redeemed here.
    public func complete(pasted: String, session: Session, now: Date = Date()) async throws -> ClaudeOAuthToken {
        guard let (code, state) = Self.parse(pasted: pasted) else {
            throw ClaudeSignInError.malformedCode
        }
        guard state.isEmpty || state == session.verifier else {
            throw ClaudeSignInError.stateMismatch
        }
        let response = try await httpClient.send(
            Self.exchangeRequest(code: code, verifier: session.verifier), timeout: timeout)
        guard response.status == 200 else {
            throw ClaudeSignInError.exchangeFailed(status: response.status)
        }
        let payload = try JSONDecoder().decode(ExchangeResponse.self, from: response.body)
        guard let access = payload.accessToken, !access.isEmpty,
              CredentialStore.hasNoControlCharacters(access),
              let refresh = payload.refreshToken, !refresh.isEmpty,
              CredentialStore.hasNoControlCharacters(refresh) else {
            throw ClaudeSignInError.missingToken
        }
        return ClaudeOAuthToken(
            accessToken: access,
            refreshToken: refresh,
            clientID: Self.clientID,
            expiresAtEpoch: now.addingTimeInterval(payload.expiresIn ?? 28_800).timeIntervalSince1970,
            subscriptionType: await subscriptionType(accessToken: access),
            scope: payload.scope ?? Self.scope
        )
    }

    /// The plan label the card shows ("Claude Max"). Best effort: a token that works for usage
    /// but not for the profile endpoint should still sign in, just without the plan chip.
    private func subscriptionType(accessToken: String) async -> String? {
        var request = URLRequest(url: Self.profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let response = try? await httpClient.send(request, timeout: timeout),
              response.status == 200,
              let profile = try? JSONDecoder().decode(ProfileResponse.self, from: response.body) else {
            return nil
        }
        if profile.account?.hasClaudeMax == true { return "max" }
        if profile.account?.hasClaudePro == true { return "pro" }
        return nil
    }

    static func exchangeRequest(code: String, verifier: String) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": verifier,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // SecRandomCopyBytes is the platform CSPRNG; fall back to the stdlib generator (also
        // cryptographically seeded) rather than shipping a predictable verifier.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct ExchangeResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: TimeInterval?
        let scope: String?
        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    private struct ProfileResponse: Decodable {
        let account: Account?
        struct Account: Decodable {
            let hasClaudeMax: Bool?
            let hasClaudePro: Bool?
            private enum CodingKeys: String, CodingKey {
                case hasClaudeMax = "has_claude_max"
                case hasClaudePro = "has_claude_pro"
            }
        }
    }
}

/// Anthropic definitively rejected NMT's stored Claude grant, so only a fresh sign-in fixes it.
/// A distinct type (not a `CredentialAccessError`) because it is the ONE credential failure the
/// user can resolve in-app, and the card keys its Sign in button off exactly this.
public struct ClaudeSignInRequired: Error, Sendable, Equatable {
    public init() {}
    public var userMessage: String { "Claude sign-in expired" }
}

public enum ClaudeSignInError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformedCode
    case stateMismatch
    case exchangeFailed(status: Int)
    case missingToken

    public var description: String {
        switch self {
        case .malformedCode:
            "That doesn't look like the code Anthropic showed — copy the whole line."
        case .stateMismatch:
            "That code is from a different sign-in attempt. Start again."
        case .exchangeFailed(let status):
            status == 400 || status == 401
                ? "Anthropic rejected the code. It may have already been used — start again."
                : "Sign-in failed (HTTP \(status)). Try again in a moment."
        case .missingToken:
            "Anthropic returned no token. Start again."
        }
    }
}
