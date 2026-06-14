import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("NativeMigrationFlags")
struct NativeMigrationFlagsTests {
    @Test func defaultPolicyIsCodexbarForClaudeAndAutoForFileBackedProviders() {
        // Claude token is Keychain-only → codexbar (silent grant) avoids prompts.
        #expect(NativeMigrationFlags.defaultPolicy(for: .claude) == .codexbar)
        // Codex/Gemini read files → native-first.
        #expect(NativeMigrationFlags.defaultPolicy(for: .codex) == .auto)
        #expect(NativeMigrationFlags.defaultPolicy(for: .gemini) == .auto)
    }

    @Test func policyFallsBackToPerProviderDefaultWhenUnsetOrInvalid() {
        #expect(NativeMigrationFlags.policy(for: .claude, in: [:]) == .codexbar)
        #expect(NativeMigrationFlags.policy(for: .codex, in: [:]) == .auto)
        #expect(NativeMigrationFlags.policy(for: .claude, in: [
            NativeMigrationFlags.policyKey(for: .claude): "bogus",
        ]) == .codexbar)
    }

    @Test func policyReadsPerProviderOverrides() {
        let values = [
            NativeMigrationFlags.policyKey(for: .claude): DataSourcePolicy.native.rawValue,
            NativeMigrationFlags.policyKey(for: .codex): DataSourcePolicy.codexbar.rawValue,
        ]

        #expect(NativeMigrationFlags.policy(for: .claude, in: values) == .native)
        #expect(NativeMigrationFlags.policy(for: .codex, in: values) == .codexbar)
        #expect(NativeMigrationFlags.policy(for: .gemini, in: values) == .auto)
    }

    @Test func fallbackOnErrorDefaultsTrueAndReadsOverrides() {
        #expect(NativeMigrationFlags.fallbackOnError(in: [:]) == true)
        #expect(NativeMigrationFlags.fallbackOnError(in: [
            NativeMigrationFlags.fallbackOnErrorKey: "false",
        ]) == false)
        #expect(NativeMigrationFlags.fallbackOnError(in: [
            NativeMigrationFlags.fallbackOnErrorKey: "true",
        ]) == true)
        #expect(NativeMigrationFlags.fallbackOnError(in: [
            NativeMigrationFlags.fallbackOnErrorKey: "invalid",
        ]) == true)
    }

    @Test func readsUserDefaultsWithoutMutatingThem() throws {
        let suiteName = "nmt.native-flags.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(DataSourcePolicy.codexbar.rawValue, forKey: NativeMigrationFlags.policyKey(for: .gemini))
        defaults.set(false, forKey: NativeMigrationFlags.fallbackOnErrorKey)

        #expect(NativeMigrationFlags.policy(for: .gemini, in: defaults) == .codexbar)
        #expect(NativeMigrationFlags.policy(for: .claude, in: defaults) == .codexbar)  // per-provider default
        #expect(NativeMigrationFlags.fallbackOnError(in: defaults) == false)
    }
}
