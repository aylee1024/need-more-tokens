import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("TokenStore (NMT's own 0600 token cache)")
struct TokenStoreTests {
    private struct Entry: Codable, Equatable {
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
    }

    @Test func roundTripsPerProvider() throws {
        let store = makeTempTokenStore()
        let gemini = Entry(accessToken: "g-acc", refreshToken: "g-ref", expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let claude = Entry(accessToken: "c-acc", refreshToken: nil, expiresAt: nil)
        store.save(gemini, for: .gemini)
        store.save(claude, for: .claude)

        #expect(store.load(Entry.self, for: .gemini) == gemini)
        #expect(store.load(Entry.self, for: .claude) == claude)
        // Providers are isolated — Codex was never written.
        #expect(store.load(Entry.self, for: .codex) == nil)
    }

    @Test func loadReturnsNilWhenAbsentOrCorrupt() throws {
        let store = makeTempTokenStore()
        #expect(store.load(Entry.self, for: .gemini) == nil)  // absent
        // A corrupt file decodes to nil (caller then bootstraps), never throws.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nmt-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("token-gemini.json"))
        #expect(TokenStore(directory: dir).load(Entry.self, for: .gemini) == nil)
    }

    @Test func writesUserOnly0600() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nmt-perm-\(UUID().uuidString)", isDirectory: true)
        let store = TokenStore(directory: dir)
        store.save(Entry(accessToken: "secret", refreshToken: "r", expiresAt: nil), for: .gemini)
        let path = dir.appendingPathComponent("token-gemini.json").path
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func clearRemovesEntry() {
        let store = makeTempTokenStore()
        store.save(Entry(accessToken: "x", refreshToken: nil, expiresAt: nil), for: .gemini)
        #expect(store.load(Entry.self, for: .gemini) != nil)
        store.clear(for: .gemini)
        #expect(store.load(Entry.self, for: .gemini) == nil)
    }
}
