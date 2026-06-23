import Foundation
import Testing
@testable import NeedMoreTokensKit

private struct ClientStubKeychainReader: KeychainReading {
    let data: Data?

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        #expect(service == "Claude Code-credentials")
        #expect(account == "andrewlee")
        return data
    }
}

private enum ClaudeClientFixture {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static let credential = """
    {
      "claudeAiOauth": {
        "accessToken": "sk-ant-oat01-claude-token",
        "expiresAt": 1800000000000,
        "scopes": ["user:profile"],
        "subscriptionType": "max"
      },
      "mcpOAuth": {
        "accessToken": "mcp-token-must-not-be-sent"
      }
    }
    """

    static let usage = """
    {
      "five_hour": {
        "utilization": 13,
        "resets_at": "2026-06-12T17:00:00Z"
      },
      "seven_day": {
        "utilization": 40,
        "resets_at": null
      },
      "seven_day_sonnet": {
        "utilization": 1,
        "resets_at": "2026-06-19T17:00:00Z"
      },
      "seven_day_opus": null,
      "extra_usage": {
        "is_enabled": true,
        "monthly_limit": 100000,
        "used_credits": 5318,
        "utilization": 5.318,
        "currency": "USD",
        "disabled_reason": null
      },
      "tangelo": {
        "ignored": true
      }
    }
    """
}

@Suite("Claude native usage client")
struct ClaudeUsageClientTests {
    @Test func mapsUsageAndSendsCapturedHeaders() async throws {
        let http = StubHTTPClient(responses: [.json(ClaudeClientFixture.usage)])
        let reader = ClientStubKeychainReader(data: Data(ClaudeClientFixture.credential.utf8))

        let partial = await ClaudeUsageClient(keychainReader: reader, ownStore: emptyClaudeOAuthStore(), tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: ClaudeClientFixture.now)

        let usage = try #require(partial.usage)
        #expect(partial.usageError == nil)
        #expect(usage.provider == .claude)
        #expect(usage.windows.map(\.period) == [.fiveHour, .weekly, .weekly])
        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly", "Weekly · Sonnet"])
        #expect(usage.windows.map(\.usedPercent) == [13, 40, 1])
        #expect(usage.planName == "Claude Max")
        let cap = try #require(usage.exactMonthlyCap)
        // Anthropic returns extra_usage in CENTS → MonetaryCap is dollars (÷100).
        #expect(abs(cap.used - 53.18) < 0.001)
        #expect(cap.limit == 1000.0)
        #expect(cap.currencyCode == "USD")
        #expect(cap.periodLabel == "Monthly cap")
        #expect(partial.cost.isAvailable == false)

        let requests = await http.recordedRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.method == "GET")
        #expect(request.headers["Authorization"] == "Bearer sk-ant-oat01-claude-token")
        #expect(request.headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(request.headers["User-Agent"] == "claude-code/2.1.0")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Content-Type"] == "application/json")
    }

    @Test func non200BecomesUsageError() async {
        let http = StubHTTPClient(responses: [.json(#"{}"#, status: 401)])
        let reader = ClientStubKeychainReader(data: Data(ClaudeClientFixture.credential.utf8))

        let partial = await ClaudeUsageClient(keychainReader: reader, ownStore: emptyClaudeOAuthStore(), tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: ClaudeClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("HTTP 401") == true)
        #expect(partial.cost.isAvailable == false)
    }

    @Test func malformedBodyBecomesUsageError() async {
        let http = StubHTTPClient(responses: [HTTPResponse(status: 200, body: Data("{".utf8), headers: [:])])
        let reader = ClientStubKeychainReader(data: Data(ClaudeClientFixture.credential.utf8))

        let partial = await ClaudeUsageClient(keychainReader: reader, ownStore: emptyClaudeOAuthStore(), tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: ClaudeClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("Claude usage unreadable") == true)
    }

    @Test func missingCredentialBecomesUsageErrorWithoutHTTP() async {
        let http = StubHTTPClient(responses: [.json(ClaudeClientFixture.usage)])
        let reader = ClientStubKeychainReader(data: nil)

        let partial = await ClaudeUsageClient(keychainReader: reader, ownStore: emptyClaudeOAuthStore(), tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: ClaudeClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("Claude credentials not found") == true)
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test func cachedAccessTokenServedWithoutKeychain() async throws {
        let now = ClaudeClientFixture.now
        let tokenStore = makeTempTokenStore()
        // A valid cached token (expires in 1h) must be served WITHOUT reading the Keychain —
        // this is what makes the periodic path prompt-free between ~8h refreshes.
        tokenStore.save(ClaudeCacheSeed(accessToken: "cached-claude", expiresAt: now.addingTimeInterval(3_600),
                                        subscriptionType: "max", scopes: nil), for: .claude)
        let http = StubHTTPClient(responses: [.json(ClaudeClientFixture.usage)])

        let partial = await ClaudeUsageClient(keychainReader: FailIfReadClaudeKeychain(), ownStore: emptyClaudeOAuthStore(), tokenStore: tokenStore, httpClient: http)
            .fetch(now: now)

        let usage = try #require(partial.usage)
        #expect(partial.usageError == nil)
        #expect(usage.planName == "Claude Max")  // recovered from the cached subscriptionType
        let reqs = await http.recordedRequests()
        #expect(reqs.count == 1)
        #expect(reqs.first?.headers["Authorization"] == "Bearer cached-claude")  // the cached token
    }

    @Test func cacheMissReadsKeychainThenCachesForNextFetch() async throws {
        let now = ClaudeClientFixture.now
        let tokenStore = makeTempTokenStore()
        let reader = ClientStubKeychainReader(data: Data(ClaudeClientFixture.credential.utf8))
        let http = StubHTTPClient(responses: [.json(ClaudeClientFixture.usage)])

        _ = await ClaudeUsageClient(keychainReader: reader, ownStore: emptyClaudeOAuthStore(), tokenStore: tokenStore, httpClient: http).fetch(now: now)

        // After a cache-miss fetch, the token is cached with the credential's real expiry.
        let cached = tokenStore.load(ClaudeCacheSeed.self, for: .claude)
        #expect(cached?.accessToken == "sk-ant-oat01-claude-token")
        #expect(cached?.subscriptionType == "max")
        // expiresAt = the fixture's expiresAt (1800000000000 ms) as a Date.
        #expect(cached?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func serverRejectedCachedTokenClearsCacheSoNextCycleRecovers() async throws {
        let now = ClaudeClientFixture.now
        let tokenStore = makeTempTokenStore()
        // Locally-valid cached token (expires in 1h) that the SERVER rejects (401) — e.g.
        // revoked out-of-band. Without clearing, NMT would keep serving it for up to ~8h.
        tokenStore.save(ClaudeCacheSeed(accessToken: "revoked", expiresAt: now.addingTimeInterval(3_600),
                                        subscriptionType: "max", scopes: nil), for: .claude)
        let http = StubHTTPClient(responses: [.json(#"{}"#, status: 401)])
        let reader = ClientStubKeychainReader(data: Data(ClaudeClientFixture.credential.utf8))

        let partial = await ClaudeUsageClient(keychainReader: reader, ownStore: emptyClaudeOAuthStore(), tokenStore: tokenStore, httpClient: http).fetch(now: now)

        #expect(partial.usageError?.contains("HTTP 401") == true)
        // Cache cleared → the next fetch re-reads the Keychain instead of serving the dead token.
        #expect(tokenStore.load(ClaudeCacheSeed.self, for: .claude) == nil)
    }
}

/// Seed shape matching `ClaudeUsageClient.Cache` (same Codable keys).
private struct ClaudeCacheSeed: Codable, Equatable {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?
    var scopes: [String]?
}

private struct FailIfReadClaudeKeychain: KeychainReading {
    func readGenericPassword(service: String, account: String?) throws -> Data? {
        Issue.record("Keychain must not be read when a cached Claude token can serve the request")
        return nil
    }
}

@Suite("Claude own OAuth token (independent, keychain-free)")
struct ClaudeOwnTokenTests {
    private func ownStore(_ token: ClaudeOAuthToken) -> ClaudeOAuthStore {
        let store = ClaudeOAuthStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("nmt-own-\(UUID().uuidString).json"))
        store.save(token)
        return store
    }
    private func token(access: String, refresh: String, expiresAtEpoch: Double?) -> ClaudeOAuthToken {
        ClaudeOAuthToken(accessToken: access, refreshToken: refresh, clientID: "cid",
                         expiresAtEpoch: expiresAtEpoch, subscriptionType: "max")
    }

    @Test func storeRoundTripsAndIsUserOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nmt-own-\(UUID().uuidString).json")
        let store = ClaudeOAuthStore(url: url)
        let t = token(access: "a", refresh: "r", expiresAtEpoch: 1_800_000_000)
        store.save(t)
        #expect(store.load() == t)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func validOwnTokenUsedWithoutKeychainOrRefresh() async throws {
        let now = ClaudeClientFixture.now
        let store = ownStore(token(access: "own-valid", refresh: "r",
                                   expiresAtEpoch: now.addingTimeInterval(3_600).timeIntervalSince1970))
        let http = StubHTTPClient(responses: [.json(ClaudeClientFixture.usage)])

        let partial = await ClaudeUsageClient(keychainReader: FailIfReadClaudeKeychain(), ownStore: store,
                                              tokenStore: makeTempTokenStore(), httpClient: http).fetch(now: now)

        let usage = try #require(partial.usage)
        #expect(usage.planName == "Claude Max")   // subscriptionType carried by the own token
        let reqs = await http.recordedRequests()
        #expect(reqs.count == 1)   // usage only — no refresh, no Keychain
        #expect(reqs.first?.headers["Authorization"] == "Bearer own-valid")
    }

    @Test func expiredOwnTokenSelfRefreshesAndPersistsRotatedToken() async throws {
        let now = ClaudeClientFixture.now
        let store = ownStore(token(access: "old-access", refresh: "old-refresh",
                                   expiresAtEpoch: now.addingTimeInterval(-10).timeIntervalSince1970))
        let http = StubHTTPClient(responses: [
            .json(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800}"#),  // refresh (rotates)
            .json(ClaudeClientFixture.usage),                                                            // usage
        ])

        let partial = await ClaudeUsageClient(keychainReader: FailIfReadClaudeKeychain(), ownStore: store,
                                              tokenStore: makeTempTokenStore(), httpClient: http).fetch(now: now)

        #expect(partial.usageError == nil)
        let reqs = await http.recordedRequests()
        #expect(reqs.count == 2)
        #expect(reqs[0].url?.absoluteString == "https://api.anthropic.com/v1/oauth/token")
        #expect(reqs[1].headers["Authorization"] == "Bearer new-access")  // refreshed token used for usage
        // LOAD-BEARING: the ROTATED refresh token is written back, or the next refresh would fail.
        let saved = store.load()
        #expect(saved?.refreshToken == "new-refresh")
        #expect(saved?.accessToken == "new-access")
        #expect(saved?.subscriptionType == "max")  // preserved across refresh
    }

    @Test func revokedOwnRefreshSurfacesReauthAndNeverTouchesKeychain() async throws {
        let now = ClaudeClientFixture.now
        let store = ownStore(token(access: "old", refresh: "dead",
                                   expiresAtEpoch: now.addingTimeInterval(-10).timeIntervalSince1970))
        let http = StubHTTPClient(responses: [.json(#"{"error":"invalid_grant"}"#, status: 400)])  // refresh rejected

        let partial = await ClaudeUsageClient(keychainReader: FailIfReadClaudeKeychain(), ownStore: store,
                                              tokenStore: makeTempTokenStore(), httpClient: http).fetch(now: now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("re-run") == true)  // clear re-auth, NOT a Keychain fallback
        let reqs = await http.recordedRequests()
        #expect(reqs.count == 1)  // the failed refresh only — never hit usage, never read the Keychain
    }

    @Test func transientRefreshFailureDoesNotDemandReauthAndKeepsToken() async throws {
        let now = ClaudeClientFixture.now
        let store = ownStore(token(access: "old", refresh: "still-good",
                                   expiresAtEpoch: now.addingTimeInterval(-10).timeIntervalSince1970))
        let http = StubHTTPClient(responses: [.json(#"{"error":"backend"}"#, status: 503)])  // transient

        let partial = await ClaudeUsageClient(keychainReader: FailIfReadClaudeKeychain(), ownStore: store,
                                              tokenStore: makeTempTokenStore(), httpClient: http).fetch(now: now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("temporarily unavailable") == true)
        #expect(partial.usageError?.contains("re-run") == false)   // a 5xx must NOT demand re-auth
        // A transient failure must not wipe/alter the still-valid refresh token (next cycle retries).
        #expect(store.load()?.refreshToken == "still-good")
    }

    @Test func descriptionRedactsTokens() {
        let s = String(describing: token(access: "SECRET-ACCESS", refresh: "SECRET-REFRESH", expiresAtEpoch: 1))
        #expect(!s.contains("SECRET-ACCESS"))
        #expect(!s.contains("SECRET-REFRESH"))
    }
}
