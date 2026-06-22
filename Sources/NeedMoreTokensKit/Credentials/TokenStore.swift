import Foundation

/// NMT's OWN on-disk token cache: one 0600 JSON file per provider that NMT fully controls.
///
/// Why this exists: NMT reads OAuth tokens that live in *other* apps' macOS Keychain items
/// (Claude Code, Antigravity/agy). A cross-app Keychain read is what triggers the macOS
/// "allow access" prompt, and that grant is not durable. By caching tokens in a file NMT
/// owns, the periodic refresh path reads this file instead of the Keychain — so after a
/// one-time bootstrap it never prompts again.
///
/// This is a thin, provider-agnostic key/value store: each client defines its own `Codable`
/// cache shape (Gemini stores a refresh token + access token; Claude stores only a cached
/// access token, because Anthropic rotates refresh tokens and NMT must not hold one). Files
/// sit beside the Gemini OAuth client config in `~/.config/needmoretokens/` as
/// `token-<provider>.json`, written user-only (0600). Each provider has its own file, so the
/// concurrent per-provider fetches never race on a shared file.
public struct TokenStore: Sendable {
    private let directory: URL

    public init(directory: URL = TokenStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/needmoretokens", isDirectory: true)
    }

    private func url(for provider: Provider) -> URL {
        directory.appendingPathComponent("token-\(provider.rawValue).json", isDirectory: false)
    }

    /// Returns the cached value for `provider`, or nil if absent / unreadable / undecodable.
    /// Never throws: a missing or corrupt cache simply means "no cache", and the caller then
    /// bootstraps from the source of truth (the Keychain).
    public func load<T: Decodable>(_ type: T.Type, for provider: Provider) -> T? {
        guard let data = try? Data(contentsOf: url(for: provider)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Writes the cached value for `provider` as a user-only (0600) file, created with those
    /// permissions from the start so the secret is never briefly group/world-readable.
    /// Best-effort: failures are swallowed because the cache is an optimization — the source
    /// of truth still works without it. A partial write (e.g. crash mid-write) decodes to nil
    /// on the next `load`, which just triggers a fresh bootstrap.
    public func save<T: Encodable>(_ value: T, for provider: Provider) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: url(for: provider).path, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    /// Removes the cached value for `provider` (e.g. on a hard re-auth). Best-effort.
    public func clear(for provider: Provider) {
        try? FileManager.default.removeItem(at: url(for: provider))
    }
}
