import Testing
@testable import NeedMoreTokensKit

/// Codex's codexbar `auto` source tries the OpenAI web dashboard first, which was
/// measured hanging ~163s on-machine and tripping the 35s usage timeout. We pin
/// Codex to `--source cli` (1.2s, same data); Claude/Gemini stay on `auto`.
@Suite("Provider usage source override")
struct ProviderSourceTests {
    @Test func codexForcesCLISource() {
        #expect(Provider.codex.usageSourceOverride == "cli")
    }

    @Test func claudeAndGeminiUseEngineDefault() {
        #expect(Provider.claude.usageSourceOverride == nil)
        #expect(Provider.gemini.usageSourceOverride == nil)
    }
}
