import Foundation
import Testing
@testable import NeedMoreTokensKit

/// Matches `GrokUsageClient.Cache` so tests can pre-seed NMT's Grok cache.
private struct GrokCacheSeed: Codable { var planName: String; var fetchedAt: Date }

private enum GrokFixture {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Writes a `~/.grok/auth.json`-shaped file and returns a loader pointed at it.
    static func authFile(expiresAt: String) throws -> (GrokCredentialLoader, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nmt-grok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        let json = #"{"https://auth.x.ai::client-1":{"key":"grok-jwt-token","expires_at":"\#(expiresAt)","refresh_token":"r"}}"#
        try Data(json.utf8).write(to: url)
        return (GrokCredentialLoader(url: url), dir)
    }

    static let proTrial = #"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE","billingPeriodEnd":"2026-06-25T17:29:26Z","activeOffer":{"type":"ACTIVE_OFFER_FREE_TRIAL","offerEnd":"2026-06-25T17:29:26Z"}}]}"#
    static let proActive = #"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE","billingPeriodEnd":"2026-07-22T00:00:00Z"}]}"#
}

@Suite("Grok usage client")
struct GrokUsageClientTests {
    @Test func activeSubscriptionMapsToPlanCardWithRenewal() async throws {
        let (loader, dir) = try GrokFixture.authFile(expiresAt: "2030-01-01T00:00:00Z")
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(GrokFixture.proActive)])

        let partial = await GrokUsageClient(credentialLoader: loader, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GrokFixture.now)

        let usage = try #require(partial.usage)
        #expect(partial.usageError == nil)
        #expect(usage.provider == .grok)
        #expect(usage.planName?.hasPrefix("Grok Pro · renews ") == true)
        #expect(usage.windows.isEmpty)            // no usage-style window (would skew the menu bar)
        #expect(partial.cost.isAvailable == false)
        // One GET to the subscriptions endpoint, bearer auth.
        let reqs = await http.recordedRequests()
        #expect(reqs.count == 1)
        #expect(reqs.first?.url?.absoluteString == "https://grok.com/rest/subscriptions")
        #expect(reqs.first?.headers["Authorization"] == "Bearer grok-jwt-token")
    }

    @Test func freeTrialShowsTrialEnds() async throws {
        let (loader, dir) = try GrokFixture.authFile(expiresAt: "2030-01-01T00:00:00Z")
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(GrokFixture.proTrial)])

        let partial = await GrokUsageClient(credentialLoader: loader, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GrokFixture.now)

        #expect(partial.usage?.planName?.hasPrefix("Grok Pro · trial ends ") == true)
    }

    @Test func expiredTokenSurfacesReauthWithoutHTTP() async throws {
        let (loader, dir) = try GrokFixture.authFile(expiresAt: "2020-01-01T00:00:00Z")  // already expired
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(GrokFixture.proActive)])

        let partial = await GrokUsageClient(credentialLoader: loader, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GrokFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("expired") == true)
        #expect(await http.recordedRequests().isEmpty)  // never hit the network with a dead token
    }

    @Test func freshCacheServedWithoutTokenOrNetwork() async throws {
        let tokenStore = makeTempTokenStore()
        tokenStore.save(GrokCacheSeed(planName: "Grok Pro · renews Jul 22", fetchedAt: GrokFixture.now), for: .grok)
        // Loader points at a missing file and the HTTP stub has no responses — a cache hit
        // must touch neither.
        let loader = GrokCredentialLoader(url: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json"))
        let http = StubHTTPClient(responses: [])

        let partial = await GrokUsageClient(credentialLoader: loader, tokenStore: tokenStore, httpClient: http)
            .fetch(now: GrokFixture.now.addingTimeInterval(60))  // within the 6h TTL

        #expect(partial.usage?.planName == "Grok Pro · renews Jul 22")
        // Served-from-cache must report the cache's real fetch time, not "now" (honesty).
        #expect(partial.usage?.updatedAt == GrokFixture.now)
        #expect(await http.recordedRequests().isEmpty)
    }

    @Test func non200WithoutCacheSurfacesError() async throws {
        let (loader, dir) = try GrokFixture.authFile(expiresAt: "2030-01-01T00:00:00Z")
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [.json(#"{}"#, status: 401)])

        let partial = await GrokUsageClient(credentialLoader: loader, tokenStore: makeTempTokenStore(), httpClient: http)
            .fetch(now: GrokFixture.now)

        #expect(partial.usage == nil)
        #expect(partial.usageError?.contains("HTTP 401") == true)
    }

    @Test func tierAndRenewalMappingIsRobust() throws {
        let trial = try JSONDecoder().decode(RawGrokSubscriptions.self, from: Data(GrokFixture.proTrial.utf8))
        #expect(GrokUsageClient.planName(from: trial)?.hasPrefix("Grok Pro · trial ends ") == true)
        // No subscriptions → nil (free tier), not a fabricated plan.
        let empty = try JSONDecoder().decode(RawGrokSubscriptions.self, from: Data(#"{"subscriptions":[]}"#.utf8))
        #expect(GrokUsageClient.planName(from: empty) == nil)

        // A CANCELLED (non-active) subscription must NOT render as a live plan — else the card
        // mislabels it and the price estimate bills a phantom $30.
        let cancelled = try JSONDecoder().decode(RawGrokSubscriptions.self,
            from: Data(#"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_GROK_PRO","status":"SUBSCRIPTION_STATUS_CANCELED","billingPeriodEnd":"2026-07-22T00:00:00Z"}]}"#.utf8))
        #expect(GrokUsageClient.planName(from: cancelled) == nil)

        // A numeric (Unix-epoch) currentPeriodEnd must NOT break decoding — degrade gracefully.
        let numeric = try JSONDecoder().decode(RawGrokSubscriptions.self,
            from: Data(#"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE","stripe":{"currentPeriodEnd":1782000000}}]}"#.utf8))
        #expect(GrokUsageClient.planName(from: numeric)?.hasPrefix("Grok Pro · renews ") == true)
    }
}
