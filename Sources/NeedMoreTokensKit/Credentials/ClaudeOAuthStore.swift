import Foundation

/// NMT's OWN Claude OAuth token — an independent, full-scope token obtained via a one-time
/// browser sign-in (the same `claude.com/cai` flow the Claude CLI uses), stored in a 0600 file
/// NMT fully controls (`~/.config/needmoretokens/claude-token.json`).
///
/// This is what makes Claude PERMANENT. Claude Code rewrites its Keychain item on every token
/// refresh, and that rewrite resets the item's ACL — repeatedly evicting NMT's "Always Allow"
/// grant (proven). By holding its OWN token, NMT never reads Claude Code's Keychain, so it can't
/// be evicted.
///
/// CRITICAL: Anthropic ROTATES the refresh token on every refresh — the NEW refresh token MUST be
/// written back here each time or the next refresh fails (verified end-to-end). The access token
/// is opaque (not a JWT), so its expiry is tracked here as `expires_at` (epoch seconds, which both
/// the install-time setup and Swift's write-back encode identically).
public struct ClaudeOAuthToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var clientID: String
    /// Absolute expiry, epoch seconds (cross-language stable: Python setup + Swift write-back agree).
    public var expiresAtEpoch: Double?
    public var subscriptionType: String?
    public var scope: String?

    public var expiresAt: Date? { expiresAtEpoch.map { Date(timeIntervalSince1970: $0) } }

    public init(accessToken: String, refreshToken: String, clientID: String,
                expiresAtEpoch: Double?, subscriptionType: String?, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.clientID = clientID
        self.expiresAtEpoch = expiresAtEpoch
        self.subscriptionType = subscriptionType
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case clientID = "client_id"
        case expiresAtEpoch = "expires_at"
        case subscriptionType = "subscription_type"
        case scope
    }
}

// Defense-in-depth (matches the other credential structs): this holds LIVE access + refresh
// tokens, and the synthesized reflection description would print them verbatim. Redact so any
// accidental log/interpolation can't leak them.
extension ClaudeOAuthToken: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ClaudeOAuthToken(clientID: \(clientID), subscriptionType: \(subscriptionType ?? "nil"), accessToken: <redacted>, refreshToken: <redacted>)"
    }
    public var debugDescription: String { description }
}

public struct ClaudeOAuthStore: Sendable {
    private let url: URL
    public init(url: URL = ClaudeOAuthStore.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/needmoretokens/claude-token.json")
    }

    /// The stored token, or nil if absent / unreadable / undecodable (caller then falls back to
    /// the Keychain). Never throws.
    public func load() -> ClaudeOAuthToken? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeOAuthToken.self, from: data)
    }

    /// Persists the token as a user-only (0600) file, created with those perms from the start.
    /// Best-effort. This is how the ROTATED refresh token survives across refreshes.
    public func save(_ token: ClaudeOAuthToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: url.path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
        // createFile may not re-apply perms when overwriting a pre-existing file; enforce 0600.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
