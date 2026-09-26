import Foundation
import Testing
@testable import NeedMoreTokensKit

private struct FixedBotToken: GrokBotTokenLoading {
    let token: String?
    func loadAccessToken(now: Date) -> String? { token }
}

private struct FixedKeychain: KeychainReading {
    let data: Data?
    func readGenericPassword(service: String, account: String?) throws -> Data? { data }
}

@Suite("Grok Bot weekly limit")
struct GrokBotUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_758_000_000) // 2025-09-16, before the fixture reset

    /// Live shape from GetSandUsageStatus on 2026-09-26, with the on-demand
    /// block removed. `usagePercent` 0.853383 is under one percent.
    private static let live = """
    {"currentPeriodStart":"2026-09-25T21:31:48.864Z","nextResetTimestampUtc":"2026-10-02T21:31:48.864Z","usagePercent":0.853383,"hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,"includedUsageSuperGrokPlan":"supergrok-plus","grokPlanLabel":"SuperGrok Plus","cursorPlanName":"Free","billingBrand":"SAND_BILLING_BRAND_CURSOR"}
    """

    @Test func livePercentIsAlreadyPercentNotAFraction() throws {
        let reply = try JSONDecoder().decode(RawGrokBotUsage.self, from: Data(Self.live.utf8))
        let window = try #require(GrokUsageClient.botWindow(from: reply, now: Self.now))
        #expect(window.label == "Weekly · Grok Bot")
        #expect(window.period == .weekly)
        #expect(window.windowMinutes == 10_080)
        #expect(window.usedPercent > 0.8)
        #expect(window.usedPercent < 1)
        #expect(window.resetsAt == EngineMapper.parseDate("2026-10-02T21:31:48.864Z"))
    }

    @Test func snakeCaseFieldsDecode() throws {
        let json = #"{"usage_percent":40,"has_non_zero_included_limit":true,"next_reset_timestamp_utc":"2026-10-02T21:31:48Z","current_period_start":"2026-09-25T21:31:48Z"}"#
        let reply = try JSONDecoder().decode(RawGrokBotUsage.self, from: Data(json.utf8))
        let window = try #require(GrokUsageClient.botWindow(from: reply, now: Self.now))
        #expect(window.usedPercent == 40)
        #expect(window.windowMinutes == 10_080)
    }

    @Test func excludedPlanDrawsNoWindow() throws {
        let cases = [
            #"{"usagePercent":0,"hasNonZeroIncludedLimit":false}"#,
            #"{"usagePercent":0,"includedLimitZero":true,"hasNonZeroIncludedLimit":true}"#,
            #"{"usagePercent":12,"usesPooledEnterpriseAllowance":true,"hasNonZeroIncludedLimit":true}"#,
            #"{"hasNonZeroIncludedLimit":true}"#,
            #"{}"#,
        ]
        for json in cases {
            let reply = try JSONDecoder().decode(RawGrokBotUsage.self, from: Data(json.utf8))
            #expect(GrokUsageClient.botWindow(from: reply, now: Self.now) == nil)
        }
    }

    @Test func unexpiredTrialWithoutIncludedLimitStillDraws() throws {
        let json = #"{"usagePercent":3,"hasNonZeroIncludedLimit":false,"sandTrialExpiresAt":"2026-12-01T00:00:00Z"}"#
        let reply = try JSONDecoder().decode(RawGrokBotUsage.self, from: Data(json.utf8))
        let window = try #require(GrokUsageClient.botWindow(from: reply, now: Self.now))
        #expect(window.usedPercent == 3)
        #expect(window.resetsAt == nil)
    }

    @Test func missingResetIsNotInventedFromTheStart() throws {
        let json = #"{"usagePercent":4,"hasNonZeroIncludedLimit":true,"currentPeriodStart":"2026-09-25T21:31:48Z"}"#
        let reply = try JSONDecoder().decode(RawGrokBotUsage.self, from: Data(json.utf8))
        let window = try #require(GrokUsageClient.botWindow(from: reply, now: Self.now))
        #expect(window.resetsAt == nil)
        #expect(window.windowMinutes == 10_080)
    }

    @Test func fetchAppendsBotWindowAndKeepsSuperGrokFirst() async throws {
        let (loader, dir) = try GrokFixtureAuth.authFile(expiresAt: "2030-01-01T00:00:00Z")
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GrokFixtureAuth.weeklyCredits),
            .json(Self.live),
            GrokFixtureAuth.noResets,
            .json(GrokFixtureAuth.proActive),
        ])
        let usage = try #require(await GrokUsageClient(
            credentialLoader: loader,
            tokenStore: makeTempTokenStore(),
            httpClient: http,
            botTokens: FixedBotToken(token: "cursor-jwt")
        ).fetch(now: GrokFixtureAuth.now).usage)
        #expect(usage.windows.map(\.label) == ["Weekly", "Weekly · Grok Bot"])
        #expect(usage.windows[0].usedPercent == 2)
        #expect(usage.windows[1].usedPercent > 0.8)
        #expect(usage.windows[1].usedPercent < 1)
        #expect(usage.extraWindows.isEmpty)
        let reqs = await http.recordedRequests()
        #expect(reqs.map(\.url?.absoluteString) == [
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus",
            "https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets",
            "https://grok.com/rest/subscriptions",
        ])
        #expect(reqs[1].method == "POST")
        #expect(reqs[1].headers["Authorization"] == "Bearer cursor-jwt")
        #expect(reqs[1].headers["Connect-Protocol-Version"] == "1")
        #expect(reqs[1].body == Data("{}".utf8))
    }

    @Test func botFailureLeavesTheSuperGrokBar() async throws {
        let (loader, dir) = try GrokFixtureAuth.authFile(expiresAt: "2030-01-01T00:00:00Z")
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = StubHTTPClient(responses: [
            .json(GrokFixtureAuth.weeklyCredits),
            .json(#"{}"#, status: 500),
            GrokFixtureAuth.noResets,
            .json(GrokFixtureAuth.proActive),
        ])
        let partial = await GrokUsageClient(
            credentialLoader: loader,
            tokenStore: makeTempTokenStore(),
            httpClient: http,
            botTokens: FixedBotToken(token: "cursor-jwt")
        ).fetch(now: GrokFixtureAuth.now)
        let usage = try #require(partial.usage)
        #expect(usage.windows.map(\.label) == ["Weekly"])
        #expect(usage.windows[0].usedPercent == 2)
        #expect(partial.usageError == nil)
    }

    @Test func chromiumV10RoundTrip() {
        let opened = ChromiumSafeStorage.open(
            base64: "djEwaDg+vrmrS4wTthyhwlbSr9Uxq4JiuMFvfsY+FJPMzMQ=",
            password: Data("nmt-test-key".utf8))
        #expect(opened == "bot-access-token")
    }

    @Test func trailingNulOnTheKeychainPasswordStillDecrypts() {
        var password = Data("nmt-test-key".utf8)
        password.append(0)
        let opened = ChromiumSafeStorage.open(
            base64: "djEwaDg+vrmrS4wTthyhwlbSr9Uxq4JiuMFvfsY+FJPMzMQ=",
            password: password)
        #expect(opened == "bot-access-token")
    }

    @Test func loaderReadsTheActiveAccount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nmt-bot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sand-secrets.json")
        let accounts: [String: Any] = [
            "active": "acct",
            "accounts": [
                "acct": ["cursor-access-token": "djEwaDg+vrmrS4wTthyhwlbSr9Uxq4JiuMFvfsY+FJPMzMQ="],
            ],
        ]
        let accountsData = try JSONSerialization.data(withJSONObject: accounts)
        let outer: [String: Any] = ["cursor-accounts": String(decoding: accountsData, as: UTF8.self)]
        try JSONSerialization.data(withJSONObject: outer).write(to: url)
        let loader = GrokBotCredentialLoader(
            url: url,
            keychain: FixedKeychain(data: Data("nmt-test-key".utf8)))
        #expect(loader.loadAccessToken(now: Self.now) == "bot-access-token")
    }

    @Test func expiredJwtIsNotReturned() throws {
        let header = Data(#"{"alg":"none"}"#.utf8).base64EncodedString()
        let payload = Data(#"{"exp":100}"#.utf8).base64EncodedString()
        let jwt = "\(header).\(payload).x"
        #expect(CredentialExpiry.codexAccessTokenKnownExpired(jwt, now: Self.now))
        #expect(CredentialExpiry.codexAccessTokenKnownExpired("not-a-jwt", now: Self.now) == false)
    }
}

/// The Grok usage fixtures live in another test file as a private enum.
/// These copies are the fields this file's fetch tests need.
private enum GrokFixtureAuth {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let proActive = #"{"subscriptions":[{"tier":"SUBSCRIPTION_TIER_GROK_PRO","status":"SUBSCRIPTION_STATUS_ACTIVE","billingPeriodEnd":"2026-07-22T00:00:00Z"}]}"#
    static let weeklyCredits = """
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-23T18:05:22.677812+00:00","end":"2026-08-30T18:05:22.677812+00:00"},"creditUsagePercent":2.0,"productUsage":[{"product":"GrokBuild","usagePercent":1.0}]}}
    """
    static let noResets = HTTPResponse(
        status: 200,
        body: GrokRemainingResetsTests.grpcWeb(tokens: []),
        headers: ["content-type": "application/grpc-web+proto"]
    )

    static func authFile(expiresAt: String) throws -> (GrokCredentialLoader, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nmt-grok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        let json = #"{"https://auth.x.ai::client-1":{"key":"grok-jwt-token","expires_at":"\#(expiresAt)","oidc_client_id":"client-1"}}"#
        try Data(json.utf8).write(to: url)
        return (GrokCredentialLoader(url: url), dir)
    }
}
