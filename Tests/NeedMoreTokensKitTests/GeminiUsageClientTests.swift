import Foundation
import Testing
@testable import NeedMoreTokensKit

private enum GeminiClientFixture {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static let loadProject = """
    {
      "cloudaicompanionProject": "parabolic-zepplin-pw532",
      "future": {
        "ignored": true
      }
    }
    """

    static let quota = """
    {
      "groups": [
        {
          "displayName": "Gemini Models",
          "description": "Models within this group: Gemini Flash, Gemini Pro",
          "buckets": [
            {
              "bucketId": "gemini-weekly",
              "displayName": "Weekly Limit",
              "window": "weekly",
              "resetTime": "2026-06-25T23:03:46Z",
              "description": "...",
              "remainingFraction": 0.9849711
            },
            {
              "bucketId": "gemini-5h",
              "displayName": "Five Hour Limit",
              "window": "5h",
              "resetTime": "2026-06-19T04:03:46Z",
              "description": "...",
              "remainingFraction": 0.96553755
            }
          ]
        },
        {
          "displayName": "Claude and GPT models",
          "buckets": [
            {
              "bucketId": "3p-weekly",
              "displayName": "Weekly Limit",
              "window": "weekly",
              "resetTime": "2026-06-25T23:03:46Z",
              "description": "...",
              "remainingFraction": 0.10
            },
            {
              "bucketId": "3p-5h",
              "displayName": "Five Hour Limit",
              "window": "5h",
              "resetTime": "2026-06-19T04:03:46Z",
              "description": "...",
              "remainingFraction": 0.20
            }
          ]
        }
      ],
      "description": "..."
    }
    """

    static let fallbackQuota = """
    {
      "groups": [
        {
          "displayName": "Renamed Gemini Models",
          "buckets": [
            {
              "bucketId": "gemini-5h",
              "displayName": "Five Hour Limit",
              "window": "5h",
              "remainingFraction": 0.5
            },
            {
              "bucketId": "3p-5h",
              "displayName": "Five Hour Limit",
              "window": "5h",
              "remainingFraction": 0.1
            }
          ]
        }
      ]
    }
    """

    static func store(geminiJSON: String = antigravityCredential(accessToken: "gemini-token")) throws -> (CredentialStore, URL) {
        try credentialStore(codexJSON: #"{"tokens":{"access_token":"codex-token"}}"#, geminiJSON: geminiJSON)
    }

    static func antigravityCredential(accessToken: String, expiry: String = "2030-01-01T00:00:00Z") -> String {
        """
        {
          "token": {
            "access_token": "\(accessToken)",
            "token_type": "Bearer",
            "refresh_token": "1//refresh",
            "expiry": "\(expiry)"
          },
          "auth_method": "consumer"
        }
        """
    }

    /// An expired Gemini credential (past expiry), optionally with a refresh token.
    static func expiredCredential(refreshToken: Bool) -> String {
        let rt = refreshToken ? "\"refresh_token\": \"1//refresh\"," : ""
        return """
        {
          "token": {
            "access_token": "stale-token",
            "token_type": "Bearer",
            \(rt)
            "expiry": "2020-01-01T00:00:00Z"
          },
          "auth_method": "consumer"
        }
        """
    }

    static let refreshResponse = #"{"access_token":"refreshed-token","expires_in":3599,"token_type":"Bearer"}"#

    /// A refresher with a stub OAuth client config + the shared stub HTTP, so refresh tests
    /// are deterministic instead of depending on a local ~/.config file.
    static func refresher(_ http: StubHTTPClient) -> GeminiTokenRefresher {
        GeminiTokenRefresher(httpClient: http, clientConfig: GeminiOAuthClientConfig(clientID: "test-id", clientSecret: "test-secret"))
    }

    static func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }
}

@Suite("Gemini native usage client")
struct GeminiUsageClientTests {
    @Test func mapsBucketsAndSendsTwoCapturedRequests() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.loadProject),
            .json(GeminiClientFixture.quota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        let usage = try #require(partial.usage)
        #expect(partial.usageError == nil)
        #expect(usage.provider == .gemini)
        #expect(usage.planName == nil)
        #expect(usage.windows.count == 2)
        #expect(usage.windows.map(\.period) == [.fiveHour, .weekly])
        #expect(usage.windows.map(\.windowMinutes) == [300, 10_080])
        #expect(usage.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(usage.windows.allSatisfy { $0.resetDescription == nil })
        #expect(abs(usage.windows[0].usedPercent - 3.446245) < 0.00001)
        #expect(abs(usage.windows[1].usedPercent - 1.50289) < 0.00001)
        #expect(usage.windows[0].resetsAt == GeminiClientFixture.date("2026-06-19T04:03:46Z"))
        #expect(usage.windows[1].resetsAt == GeminiClientFixture.date("2026-06-25T23:03:46Z"))
        #expect(usage.windows.allSatisfy { !$0.label.contains("3p") })
        #expect(partial.cost.isAvailable == false)

        let requests = await http.recordedRequests()
        #expect(requests.count == 2)
        let load = requests[0]
        #expect(load.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        #expect(load.method == "POST")
        #expect(load.headers["Authorization"] == "Bearer gemini-token")
        #expect(load.headers["Content-Type"] == "application/json")
        let loadBody = try jsonObject(from: load.body)
        #expect((loadBody["metadata"] as? [String: Any])?["ideType"] as? String == "ANTIGRAVITY")

        let quota = requests[1]
        #expect(quota.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
        #expect(quota.method == "POST")
        #expect(quota.headers["Authorization"] == "Bearer gemini-token")
        #expect(quota.headers["Content-Type"] == "application/json")
        #expect(quota.headers["User-Agent"] == "antigravity/cli/1.0.9 darwin/arm64")
        let quotaBody = try jsonObject(from: quota.body)
        #expect(quotaBody["project"] as? String == "parabolic-zepplin-pw532")
        #expect(Set(quotaBody.keys) == Set(["project"]))
    }

    @Test func missingProjectBecomesUsageErrorWithoutQuotaRequest() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(#"{}"#),
            .json(GeminiClientFixture.quota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("Gemini usage unreadable") == true)
        let requests = await http.recordedRequests()
        #expect(requests.count == 1)
    }

    @Test func fallsBackToGeminiBucketIDsWhenGroupDisplayNameChanges() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.loadProject),
            .json(GeminiClientFixture.fallbackQuota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        let usage = try #require(partial.usage)
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "5-hour")
        #expect(usage.windows[0].usedPercent == 50)
    }

    @Test func non200BecomesUsageError() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.loadProject),
            .json(#"{}"#, status: 403),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("HTTP 403") == true)
        #expect(partial.cost.isAvailable == false)
    }

    @Test func malformedBodyBecomesUsageError() async throws {
        let (store, dir) = try GeminiClientFixture.store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.loadProject),
            HTTPResponse(status: 200, body: Data("{".utf8), headers: [:]),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("Gemini usage unreadable") == true)
    }

    @Test func refreshesExpiredTokenThenUsesNewTokenForQuota() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.refreshResponse),  // OAuth refresh exchange
            .json(GeminiClientFixture.loadProject),
            .json(GeminiClientFixture.quota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http, refresher: GeminiClientFixture.refresher(http))
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usageError == nil)
        #expect(partial.usage != nil)
        let requests = await http.recordedRequests()
        #expect(requests.count == 3)
        // First call is the refresh; subsequent calls must carry the REFRESHED token.
        #expect(requests[0].url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(requests[0].method == "POST")
        #expect(requests[1].headers["Authorization"] == "Bearer refreshed-token")
        #expect(requests[2].headers["Authorization"] == "Bearer refreshed-token")
    }

    @Test func expiredTokenWithoutLocalOAuthConfigFallsBackToExpiredWithoutHTTP() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [])
        // No local OAuth client configured → auto-refresh is opt-in, so the card falls back
        // to today's "expired" state and never attempts the refresh call.
        let refresher = GeminiTokenRefresher(httpClient: http, clientConfig: nil)

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http, refresher: refresher)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("expired") == true)
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test func expiredTokenWithoutRefreshTokenSurfacesReauthWithoutHTTP() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: false))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(GeminiClientFixture.loadProject)])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("expired") == true)
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test func failedRefreshSurfacesReauthAfterOnlyTheRefreshCall() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(#"{"error":"invalid_grant"}"#, status: 400),  // refresh rejected
        ])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http, refresher: GeminiClientFixture.refresher(http),
                                              refreshMaxAttempts: 1, refreshRetryBaseDelay: 0)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        // A failed refresh now surfaces the clean "expired — run agy" message, not an HTTP error.
        #expect(partial.usageError?.contains("expired") == true)
        #expect(partial.usageError?.contains("HTTP") == false)
        #expect(await http.recordedRequests().count == 1)
    }

    @Test func transientRefreshFailureIsRetriedThenSucceeds() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(#"{"error":"backend"}"#, status: 503),     // refresh attempt 1: transient
            .json(GeminiClientFixture.refreshResponse),       // refresh attempt 2: succeeds
            .json(GeminiClientFixture.loadProject),
            .json(GeminiClientFixture.quota),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http, refresher: GeminiClientFixture.refresher(http),
                                              refreshMaxAttempts: 3, refreshRetryBaseDelay: 0)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usageError == nil)
        #expect(partial.usage != nil)
        let requests = await http.recordedRequests()
        #expect(requests.count == 4)  // 503 refresh, 200 refresh, loadProject, quota
        #expect(requests[0].url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(requests[1].url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(requests[2].headers["Authorization"] == "Bearer refreshed-token")
        #expect(requests[3].headers["Authorization"] == "Bearer refreshed-token")
    }

    @Test func persistentRefreshFailureSurfacesExpiredAfterRetries() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(#"{"error":"backend"}"#, status: 503),
            .json(#"{"error":"backend"}"#, status: 503),
            .json(#"{"error":"backend"}"#, status: 503),
        ])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http, refresher: GeminiClientFixture.refresher(http),
                                              refreshMaxAttempts: 3, refreshRetryBaseDelay: 0)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("expired") == true)
        #expect(partial.usageError?.contains("HTTP") == false)
        #expect(await http.recordedRequests().count == 3)  // all 3 attempts made, then expired
    }

    @Test func missingConfigDoesNotRetry() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: GeminiClientFixture.expiredCredential(refreshToken: true))
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [])
        let refresher = GeminiTokenRefresher(httpClient: http, clientConfig: nil)  // no local OAuth client

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http, refresher: refresher,
                                              refreshMaxAttempts: 3, refreshRetryBaseDelay: 0)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("expired") == true)
        #expect(await http.recordedRequests().isEmpty)  // clientConfigMissing → no HTTP, no retry
    }

    @Test func missingCredentialBecomesUsageErrorWithoutHTTP() async throws {
        let (store, dir) = try GeminiClientFixture.store(geminiJSON: #"{"token":{"token_type":"Bearer","expiry":"2030-01-01T00:00:00Z"},"auth_method":"consumer"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(GeminiClientFixture.loadProject)])

        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GeminiClientFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("access token missing") == true)
        #expect(await http.recordedRequests().isEmpty)
    }

    // LIVE integration (gated; NOT run in CI): proves the running-app refresh path end-to-end.
    // Reads the REAL Antigravity Keychain credential, forces the cached token to look expired,
    // then exchanges the REAL refresh token via the REAL local OAuth config against Google and
    // hits the live Code Assist quota API. Run with: NMT_LIVE=1 swift test --filter LIVE_refresh
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NMT_LIVE"] != nil))
    func LIVE_refreshesRealExpiredTokenAndReadsQuota() async throws {
        let security = Process()
        security.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        security.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        let pipe = Pipe()
        security.standardOutput = pipe
        try security.run()
        security.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        let credentialJSON: String
        if out.hasPrefix(prefix), let data = Data(base64Encoded: String(out.dropFirst(prefix.count))) {
            credentialJSON = String(decoding: data, as: UTF8.self)
        } else {
            credentialJSON = out
        }

        let (store, dir) = try GeminiClientFixture.store(geminiJSON: credentialJSON)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Real OAuth config (~/.config/needmoretokens/gemini-oauth.json) + real network.
        let client = GeminiUsageClient(credentialStore: store, tokenStore: makeTempTokenStore(),
                                       httpClient: URLSessionHTTPClient(),
                                       refresher: GeminiTokenRefresher())
        // now = +2h forces resolveAccessToken down the expired → refresh branch.
        let partial = await client.fetch(now: Date(timeIntervalSinceNow: 7200))

        print("LIVE usageError:", partial.usageError ?? "nil")
        print("LIVE windows:", partial.usage?.windows.map { "\($0.label)=\($0.usedPercent)%" } ?? [])
        #expect(partial.usageError == nil)
        #expect(partial.usage != nil)
    }

    // MARK: - Self-own (TokenStore) behavior

    @Test func cachedAccessTokenServedWithoutKeychainOrRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokenStore = makeTempTokenStore()
        tokenStore.save(GeminiCacheSeed(accessToken: "cached-access", refreshToken: "1//r",
                                        expiresAt: now.addingTimeInterval(3_600)), for: .gemini)
        let http = StubHTTPClient(responses: [.json(GeminiClientFixture.loadProject), .json(GeminiClientFixture.quota)])
        // Keychain read FAILS the test if invoked — a cache hit must not touch it.
        let store = CredentialStore(geminiKeychainReader: FailIfReadGeminiKeychain())
        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: tokenStore, httpClient: http,
                                              refresher: GeminiClientFixture.refresher(http)).fetch(now: now)

        #expect(partial.usageError == nil)
        #expect(partial.usage != nil)
        let reqs = await http.recordedRequests()
        #expect(reqs.count == 2)  // loadProject + quota only — no refresh, no Keychain
        #expect(reqs.first?.url?.absoluteString.contains("loadCodeAssist") == true)
    }

    @Test func selfRefreshesFromStoredRefreshTokenWithoutKeychain() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokenStore = makeTempTokenStore()
        // Stored refresh token, but the cached access token is expired → self-refresh, no Keychain.
        tokenStore.save(GeminiCacheSeed(accessToken: "old", refreshToken: "1//stored",
                                        expiresAt: now.addingTimeInterval(-10)), for: .gemini)
        let http = StubHTTPClient(responses: [
            .json(GeminiClientFixture.refreshResponse),
            .json(GeminiClientFixture.loadProject),
            .json(GeminiClientFixture.quota),
        ])
        let store = CredentialStore(geminiKeychainReader: FailIfReadGeminiKeychain())
        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: tokenStore, httpClient: http,
                                              refresher: GeminiClientFixture.refresher(http)).fetch(now: now)

        #expect(partial.usageError == nil)
        #expect(partial.usage != nil)
        let reqs = await http.recordedRequests()
        #expect(reqs.count == 3)  // refresh + loadProject + quota; no Keychain read
        #expect(reqs[0].url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(reqs[1].headers["Authorization"] == "Bearer refreshed-token")
        // The refreshed token is cached for next time (so the next fetch is a pure cache hit).
        #expect(tokenStore.load(GeminiCacheSeed.self, for: .gemini)?.accessToken == "refreshed-token")
    }

    @Test func revokedStoredRefreshTokenReBootstrapsFromKeychain() async throws {
        let (store, dir) = try GeminiClientFixture.store()  // Keychain: valid access + refresh token
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokenStore = makeTempTokenStore()
        // Stored refresh token is dead (an agy re-auth rotated it) → 400 → re-bootstrap from Keychain.
        tokenStore.save(GeminiCacheSeed(accessToken: nil, refreshToken: "1//dead", expiresAt: nil), for: .gemini)
        let http = StubHTTPClient(responses: [
            .json(#"{"error":"invalid_grant"}"#, status: 400),
            .json(GeminiClientFixture.loadProject),
            .json(GeminiClientFixture.quota),
        ])
        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: tokenStore, httpClient: http,
                                              refresher: GeminiClientFixture.refresher(http),
                                              refreshMaxAttempts: 1, refreshRetryBaseDelay: 0).fetch(now: now)

        #expect(partial.usageError == nil)
        #expect(partial.usage != nil)
        let reqs = await http.recordedRequests()
        #expect(reqs.count == 3)  // dead-RT refresh (400) → Keychain bootstrap → loadProject + quota
        #expect(reqs[0].url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(reqs[1].headers["Authorization"] == "Bearer gemini-token")  // the Keychain's token
    }

    @Test func serverRejectedCachedTokenClearsGeminiCache() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokenStore = makeTempTokenStore()
        // Locally-valid cached access token the server rejects (loadCodeAssist 401).
        tokenStore.save(GeminiCacheSeed(accessToken: "revoked", refreshToken: "1//r",
                                        expiresAt: now.addingTimeInterval(3_600)), for: .gemini)
        let http = StubHTTPClient(responses: [.json(#"{}"#, status: 401)])
        // Cache hit serves the token → Keychain must NOT be read on this attempt.
        let store = CredentialStore(geminiKeychainReader: FailIfReadGeminiKeychain())
        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: tokenStore, httpClient: http,
                                              refresher: GeminiClientFixture.refresher(http)).fetch(now: now)

        #expect(partial.usageError != nil)  // 401 on loadCodeAssist → unreadable
        // Cache cleared so the next cycle re-reads/refreshes instead of serving the dead token.
        #expect(tokenStore.load(GeminiCacheSeed.self, for: .gemini) == nil)
    }

    @Test func cacheFallbackToKeychainWhenClientConfigMissing() async throws {
        let (store, dir) = try GeminiClientFixture.store()  // Keychain: valid access + refresh token
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokenStore = makeTempTokenStore()
        
        // Cache has a refresh token, but access token is nil/expired.
        tokenStore.save(GeminiCacheSeed(accessToken: nil, refreshToken: "1//stored", expiresAt: nil), for: .gemini)
        
        // No client config.
        let refresher = GeminiTokenRefresher(clientConfig: nil)
        let http = StubHTTPClient(responses: [.json(GeminiClientFixture.loadProject), .json(GeminiClientFixture.quota)])
        
        let partial = await GeminiUsageClient(credentialStore: store, tokenStore: tokenStore, httpClient: http,
                                              refresher: refresher, refreshMaxAttempts: 1, refreshRetryBaseDelay: 0).fetch(now: now)
        
        // NMT should have read the Keychain and returned the valid "gemini-token" instead of failing with expired.
        #expect(partial.usageError == nil)
        #expect(partial.usage != nil)
    }
}

/// Seed shape matching `GeminiUsageClient.Cache` (same Codable keys) so tests can pre-populate
/// NMT's token cache and assert what it serves.
private struct GeminiCacheSeed: Codable, Equatable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
}

/// A Keychain reader that fails the test if read — used to prove a cached/stored token serves
/// the request without any Keychain access.
private struct FailIfReadGeminiKeychain: KeychainReading {
    func readGenericPassword(service: String, account: String?) throws -> Data? {
        Issue.record("Keychain must not be read when a cached/stored token can serve the request")
        return nil
    }
}
