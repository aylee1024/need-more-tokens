import Foundation

/// Failure modes of a single codexbar invocation, mapped from process exit codes
/// (documented by codexbar: 0 ok · 2 provider missing · 3 parse/format · 4 timeout
/// · 1 unexpected) and from launch failures.
public enum EngineError: Error, Sendable, Equatable {
    /// codexbar itself could not be found or launched (ENOENT). Drives onboarding.
    case binaryMissing
    /// Exit 2 — a provider's own binary/PATH dependency is missing.
    case providerMissing
    /// Exit 3 — codexbar produced unparseable output. Carries stderr.
    case badOutput(String)
    /// Exit 4, or our own deadline elapsed and we killed the process.
    case timeout
    /// Exit 1 or any other nonzero status. Carries stderr.
    case unexpected(String)

    public var isRecoverableByRetry: Bool {
        switch self {
        case .timeout, .unexpected: true
        case .binaryMissing, .providerMissing, .badOutput: false
        }
    }

    /// Short, user-facing description for menu-bar / onboarding surfaces.
    public var userMessage: String {
        switch self {
        case .binaryMissing: "codexbar engine not found"
        case .providerMissing: "Provider source unavailable"
        case .badOutput: "Unreadable engine output"
        case .timeout: "Timed out"
        // Do NOT surface the associated message: it is codexbar's raw stderr
        // ("exit N: <stderr>") which can carry account/path/token-shaped material.
        // The stderr stays in the error value for diagnostics, never in user text.
        case .unexpected: "Unexpected engine error"
        }
    }
}
