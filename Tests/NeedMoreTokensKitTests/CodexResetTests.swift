import Testing
@testable import NeedMoreTokensKit

@Suite("CodexReset")
struct CodexResetTests {
    @Test func featureVisibleOnlyForCodexWithKnownCount() {
        #expect(CodexReset.isFeatureVisible(provider: .codex, resetCount: 1))
        #expect(CodexReset.isFeatureVisible(provider: .codex, resetCount: 0))
        #expect(!CodexReset.isFeatureVisible(provider: .codex, resetCount: nil))
        #expect(!CodexReset.isFeatureVisible(provider: .claude, resetCount: 1))
        #expect(!CodexReset.isFeatureVisible(provider: .claude, resetCount: nil))
        #expect(!CodexReset.isFeatureVisible(provider: .gemini, resetCount: 1))
        #expect(!CodexReset.isFeatureVisible(provider: .gemini, resetCount: nil))
    }

    @Test func bannerTextPluralizesResetCount() {
        #expect(CodexReset.bannerText(count: 0) == "0 resets banked")
        #expect(CodexReset.bannerText(count: 1) == "1 reset banked")
        #expect(CodexReset.bannerText(count: 2) == "2 resets banked")
    }
}
