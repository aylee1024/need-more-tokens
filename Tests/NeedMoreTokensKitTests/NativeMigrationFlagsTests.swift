import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("NativeMigrationFlags")
struct NativeMigrationFlagsTests {
    @Test func defaultPolicyIsNativeForEveryProvider() {
        // Fully native: Codex reads a file; Claude+Gemini read the Keychain with background
        // prompts disabled + a one-time user grant. codexbar is no longer a default source.
        #expect(NativeMigrationFlags.defaultPolicy(for: .claude) == .native)
        #expect(NativeMigrationFlags.defaultPolicy(for: .codex) == .native)
        #expect(NativeMigrationFlags.defaultPolicy(for: .gemini) == .native)
    }

    @Test func policyFallsBackToNativeDefaultWhenUnsetOrInvalid() {
        #expect(NativeMigrationFlags.policy(for: .claude, in: [:]) == .native)
        #expect(NativeMigrationFlags.policy(for: .codex, in: [:]) == .native)
        #expect(NativeMigrationFlags.policy(for: .claude, in: [
            NativeMigrationFlags.policyKey(for: .claude): "bogus",
        ]) == .native)
    }

    @Test func policyReadsPerProviderOverrides() {
        let values = [
            NativeMigrationFlags.policyKey(for: .claude): DataSourcePolicy.codexbar.rawValue,
            NativeMigrationFlags.policyKey(for: .codex): DataSourcePolicy.auto.rawValue,
        ]

        // An explicit codexbar override is still honored (manual opt-in).
        #expect(NativeMigrationFlags.policy(for: .claude, in: values) == .codexbar)
        #expect(NativeMigrationFlags.policy(for: .codex, in: values) == .auto)
        // Unset → native default.
        #expect(NativeMigrationFlags.policy(for: .gemini, in: values) == .native)
    }

    @Test func fallbackOnErrorDefaultsFalseAndReadsOverrides() {
        // codexbar retired from the default path → no silent fallback unless turned on.
        #expect(NativeMigrationFlags.fallbackOnError(in: [:]) == false)
        #expect(NativeMigrationFlags.fallbackOnError(in: [
            NativeMigrationFlags.fallbackOnErrorKey: "true",
        ]) == true)
        #expect(NativeMigrationFlags.fallbackOnError(in: [
            NativeMigrationFlags.fallbackOnErrorKey: "false",
        ]) == false)
        #expect(NativeMigrationFlags.fallbackOnError(in: [
            NativeMigrationFlags.fallbackOnErrorKey: "invalid",
        ]) == false)
    }

    @Test func readsUserDefaultsWithoutMutatingThem() throws {
        let suiteName = "nmt.native-flags.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(DataSourcePolicy.codexbar.rawValue, forKey: NativeMigrationFlags.policyKey(for: .gemini))
        defaults.set(true, forKey: NativeMigrationFlags.fallbackOnErrorKey)

        #expect(NativeMigrationFlags.policy(for: .gemini, in: defaults) == .codexbar)
        #expect(NativeMigrationFlags.policy(for: .claude, in: defaults) == .native)  // native default
        #expect(NativeMigrationFlags.fallbackOnError(in: defaults) == true)
    }
}
