import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Claude in-app sign-in")
struct ClaudeSignInTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Authorize URL

    @Test func authorizeURLCarriesTheConsumerEndpointAndFullScope() throws {
        let session = ClaudeSignIn.begin(verifier: "test-verifier")
        let components = try #require(URLComponents(url: session.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        // The CONSUMER endpoint is load-bearing: the platform one caps this client at
        // user:profile, and /api/oauth/usage 403s such a token.
        #expect(session.url.host == "claude.com")
        #expect(components.path == "/cai/oauth/authorize")
        #expect(items["client_id"] == ClaudeSignIn.clientID)
        #expect(items["response_type"] == "code")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == ClaudeSignIn.redirectURI)
        let scope = try #require(items["scope"] ?? nil)
        for required in ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers"] {
            #expect(scope.contains(required))
        }
    }

    @Test func codeChallengeIsTheSHA256OfTheVerifierNotTheVerifier() throws {
        let session = ClaudeSignIn.begin(verifier: "test-verifier")
        let items = URLComponents(url: session.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let challenge = try #require(items.first { $0.name == "code_challenge" }?.value)
        // S256 of "test-verifier", base64url unpadded — computed independently with Python's
        // hashlib, NOT copied from this implementation's own output.
        #expect(challenge == "JBbiqONGWPaAmwXk_8bT6UnlPfrn65D32eZlJS-zGG0")
        #expect(challenge != "test-verifier")
        #expect(!challenge.contains("="))   // base64url: no padding, no + or /
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }

    @Test func eachAttemptGetsADistinctVerifier() {
        let verifiers = (0..<50).map { _ in ClaudeSignIn.randomVerifier() }
        #expect(Set(verifiers).count == 50)
        #expect(verifiers.allSatisfy { $0.count >= 40 })
    }

    // MARK: - Pasted code parsing

    @Test func parsesCodeAndStateAcrossRealisticPastes() throws {
        let parsed = try #require(ClaudeSignIn.parse(pasted: "  abc123#state-xyz \n"))
        #expect(parsed.code == "abc123")
        #expect(parsed.state == "state-xyz")

        let bare = try #require(ClaudeSignIn.parse(pasted: "abc123"))
        #expect(bare.code == "abc123")
        #expect(bare.state == "")

        #expect(ClaudeSignIn.parse(pasted: "   ") == nil)
        #expect(ClaudeSignIn.parse(pasted: "#only-state") == nil)
    }

    /// The clipboard watcher spends whatever it accepts against the endpoint, so anything
    /// that isn't unmistakably a code must be ignored.
    @Test func clipboardFilterAcceptsOnlyCodeShapedStrings() {
        #expect(ClaudeSignIn.looksLikeCode("aBcD1234efgh5678#Zm9vYmFyYmF6cXV4"))

        #expect(!ClaudeSignIn.looksLikeCode(""))
        #expect(!ClaudeSignIn.looksLikeCode("hello world"))
        #expect(!ClaudeSignIn.looksLikeCode("abc123"))                      // no state
        #expect(!ClaudeSignIn.looksLikeCode("short#s"))                     // too short
        #expect(!ClaudeSignIn.looksLikeCode("https://example.com/x#frag"))  // a URL, not a code
        #expect(!ClaudeSignIn.looksLikeCode("code with spaces#state12345"))
        #expect(!ClaudeSignIn.looksLikeCode(String(repeating: "a", count: 600) + "#state12345"))
    }

    // MARK: - Exchange

    @Test func exchangePostsPKCEFieldsAndReturnsAStorableToken() async throws {
        let session = ClaudeSignIn.begin(verifier: "verifier-1")
        let http = StubHTTPClient(responses: [
            .json(#"{"access_token":"acc","refresh_token":"ref","expires_in":28800,"scope":"user:profile"}"#),
            .json(#"{"account":{"has_claude_max":true}}"#),
        ])

        let token = try await ClaudeSignIn(httpClient: http)
            .complete(pasted: "the-code#verifier-1", session: session, now: now)

        #expect(token.accessToken == "acc")
        #expect(token.refreshToken == "ref")
        #expect(token.clientID == ClaudeSignIn.clientID)
        #expect(token.subscriptionType == "max")
        #expect(token.expiresAtEpoch == now.addingTimeInterval(28_800).timeIntervalSince1970)

        let requests = await http.recordedRequests()
        #expect(requests[0].url?.absoluteString == "https://api.anthropic.com/v1/oauth/token")
        let body = try #require(requests[0].body)
        let fields = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "the-code")
        #expect(fields["code_verifier"] == "verifier-1")
        #expect(fields["redirect_uri"] == ClaudeSignIn.redirectURI)
    }

    /// A code echoing a DIFFERENT state belongs to another attempt; spending it would bind the
    /// app to a token this session can't vouch for.
    @Test func codeFromAnotherAttemptIsRejectedWithoutSpendingIt() async throws {
        let session = ClaudeSignIn.begin(verifier: "mine")
        let http = StubHTTPClient(responses: [.json(#"{"access_token":"a","refresh_token":"r"}"#)])

        await #expect(throws: ClaudeSignInError.stateMismatch) {
            try await ClaudeSignIn(httpClient: http)
                .complete(pasted: "code#someone-elses", session: session, now: now)
        }
        #expect(await http.recordedRequests().isEmpty)   // never hit the endpoint
    }

    @Test func rejectedCodeSurfacesAPlainExplanation() async throws {
        let session = ClaudeSignIn.begin(verifier: "v")
        let http = StubHTTPClient(responses: [.json(#"{"error":"invalid_grant"}"#, status: 400)])

        await #expect(throws: ClaudeSignInError.exchangeFailed(status: 400)) {
            try await ClaudeSignIn(httpClient: http).complete(pasted: "code#v", session: session, now: now)
        }
        #expect(ClaudeSignInError.exchangeFailed(status: 400).description.contains("already been used"))
    }

    @Test func tokenlessSuccessResponseIsTreatedAsFailure() async throws {
        let session = ClaudeSignIn.begin(verifier: "v")
        let http = StubHTTPClient(responses: [.json(#"{"token_type":"bearer"}"#)])

        await #expect(throws: ClaudeSignInError.missingToken) {
            try await ClaudeSignIn(httpClient: http).complete(pasted: "code#v", session: session, now: now)
        }
    }

    /// The plan chip is cosmetic; a profile-endpoint failure must not block the sign-in.
    @Test func profileFailureStillSignsInWithoutAPlanLabel() async throws {
        let session = ClaudeSignIn.begin(verifier: "v")
        let http = StubHTTPClient(responses: [
            .json(#"{"access_token":"acc","refresh_token":"ref","expires_in":100}"#),
            .json(#"{}"#, status: 500),
        ])

        let token = try await ClaudeSignIn(httpClient: http)
            .complete(pasted: "code#v", session: session, now: now)

        #expect(token.accessToken == "acc")
        #expect(token.subscriptionType == nil)
    }

    // MARK: - The flag the card reads

    /// The button only appears if the flag survives the whole path from the fetch to the entry
    /// the card renders. Testing the client alone would leave that path unproven.
    @Test func signInFlagReachesTheRenderedEntryAndOnlyForThatProvider() throws {
        let fetch = ProviderFetch(usages: [:],
                                  usageErrors: [.claude: "Claude sign-in expired",
                                                .gemini: "Gemini temporarily unavailable"],
                                  costs: [:],
                                  generatedAt: now,
                                  providersNeedingSignIn: [.claude])

        let snapshot = WidgetSnapshot.build(from: fetch, enabledProviders: [.claude, .gemini],
                                            subscriptionOverrides: [:])

        let claude = try #require(snapshot.entries.first { $0.provider == .claude })
        let gemini = try #require(snapshot.entries.first { $0.provider == .gemini })
        #expect(claude.requiresSignIn == true)
        #expect(gemini.requiresSignIn == false)   // a transient failure must not offer sign-in
    }

    /// Old snapshots on disk predate the field; they must still decode (a throw would blank the
    /// widget), and must default to "no sign-in needed" rather than showing a spurious button.
    @Test func snapshotWrittenByAnOlderBuildStillDecodes() throws {
        let json = #"""
        {"provider":"claude","windows":[],"extraWindows":[],
         "cost":{"isAvailable":false,"isEstimated":false,"currencyCode":"USD"},
         "state":"error"}
        """#
        let entry = try JSONDecoder().decode(WidgetSnapshot.Entry.self, from: Data(json.utf8))
        #expect(entry.requiresSignIn == false)
    }

    /// The whole point of the flow: what it produces must survive a round-trip through the
    /// store the usage client reads, or the card stays dark after a "successful" sign-in.
    @Test func signedInTokenRoundTripsThroughTheStoreTheClientReads() async throws {
        let session = ClaudeSignIn.begin(verifier: "v")
        let http = StubHTTPClient(responses: [
            .json(#"{"access_token":"acc","refresh_token":"ref","expires_in":28800}"#),
            .json(#"{"account":{"has_claude_max":true}}"#),
        ])
        let token = try await ClaudeSignIn(httpClient: http)
            .complete(pasted: "code#v", session: session, now: now)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nmt-signin-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ClaudeOAuthStore(url: url)
        store.save(token)

        let loaded = try #require(store.load())
        #expect(loaded == token)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }
}
