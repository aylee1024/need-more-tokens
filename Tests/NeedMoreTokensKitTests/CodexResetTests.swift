import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("CodexReset")
struct CodexResetTests {
    @Test func featureVisibleOnlyForCodexWithKnownCount() {
        #expect(CodexReset.isFeatureVisible(provider: .codex, resetCount: 1))
        #expect(CodexReset.isFeatureVisible(provider: .codex, resetCount: 0))
        #expect(!CodexReset.isFeatureVisible(provider: .codex, resetCount: nil))
        #expect(CodexReset.isFeatureVisible(provider: .grok, resetCount: 1))
        #expect(CodexReset.isFeatureVisible(provider: .grok, resetCount: 0))
        #expect(!CodexReset.isFeatureVisible(provider: .grok, resetCount: nil))
        #expect(!CodexReset.isFeatureVisible(provider: .claude, resetCount: 1))
        #expect(!CodexReset.isFeatureVisible(provider: .claude, resetCount: nil))
        #expect(!CodexReset.isFeatureVisible(provider: .gemini, resetCount: 1))
        #expect(!CodexReset.isFeatureVisible(provider: .gemini, resetCount: nil))
    }

    @Test func bannerTextPluralizesResetCount() {
        #expect(CodexReset.bannerText(count: 0) == "0 resets banked")
        #expect(CodexReset.bannerText(count: 1) == "1 reset banked")
        #expect(CodexReset.bannerText(count: 2) == "2 resets banked")
        let when = Date(timeIntervalSince1970: 1_789_238_940)
        let formatted = when.formatted(date: .abbreviated, time: .shortened)
        #expect(CodexReset.bannerText(count: 1, expiresAt: when) == "1 reset banked, expires \(formatted)")
        #expect(CodexReset.bannerText(count: 2, expiresAt: when) == "2 resets banked, soonest expires \(formatted)")
        #expect(CodexReset.bannerText(count: 0, expiresAt: when) == "0 resets banked")
    }

    @Test func grokUsageURLPointsAtSettingsUsage() {
        #expect(CodexReset.grokUsageURL.absoluteString == "https://grok.com/?_s=usage")
    }
}
