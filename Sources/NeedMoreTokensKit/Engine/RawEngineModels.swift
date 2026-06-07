import Foundation

// Decodes the `codexbar` CLI JSON output exactly as it is on the wire, tolerantly.
//
// Design rule (the upgrade-resilience boundary): EVERY field is optional and
// unknown keys are ignored, so a `brew upgrade codexbar` that adds, renames, or
// drops a field degrades one value instead of breaking the whole decode. These
// `Raw*` types are mapped into clean domain types by `EngineMapper`; nothing above
// the mapper ever sees them. Shapes verified against real output from codexbar
// 0.32.0 (CLI providers reporting versions 0.135.0 / 0.45.2), 2026-06-06.
//
// `codexbar ... --format json --provider all` emits a JSON ARRAY of these
// envelopes (one per provider). Error results are envelopes carrying `error`
// (and may report `provider:"cli"` rather than the real provider id).

// MARK: - Usage

public struct RawUsageEnvelope: Decodable, Sendable {
    public let provider: String?
    public let version: String?
    public let source: String?
    public let status: RawStatus?
    public let usage: RawUsage?
    public let credits: RawCredits?
    public let error: RawError?
}

public struct RawUsage: Decodable, Sendable {
    public let primary: RawWindow?
    public let secondary: RawWindow?
    public let tertiary: RawWindow?
    public let extraRateWindows: [RawExtraWindow]?
    public let accountEmail: String?
    public let loginMethod: String?
    public let providerCost: RawProviderCost?  // Claude exposes an exact monthly spend cap here
    public let updatedAt: String?
    // `identity` is decoded leniently — its nested shape is not load-bearing for us.
}

/// An exact monetary cap from the provider's dashboard (observed on Claude:
/// `{ used, limit, period: "Monthly cap", currencyCode }`). Distinct from the
/// estimated token×price figure produced by the `cost` command.
public struct RawProviderCost: Decodable, Sendable {
    public let used: Double?
    public let limit: Double?
    public let currencyCode: String?
    public let period: String?
    public let updatedAt: String?
}

public struct RawWindow: Decodable, Sendable {
    public let usedPercent: Double?
    public let windowMinutes: Int?
    public let resetsAt: String?
    public let resetDescription: String?
}

public struct RawExtraWindow: Decodable, Sendable {
    public let id: String?
    public let title: String?
    public let window: RawWindow?
}

public struct RawCredits: Decodable, Sendable {
    public let remaining: Double?
    public let updatedAt: String?
    // `events` array is intentionally ignored.
}

public struct RawStatus: Decodable, Sendable {
    public let indicator: String?
    public let description: String?
    public let updatedAt: String?
    public let url: String?
}

public struct RawError: Decodable, Sendable {
    public let code: Int?
    public let kind: String?
    public let message: String?
}

// MARK: - Cost

public struct RawCostEnvelope: Decodable, Sendable {
    public let provider: String?
    public let source: String?
    public let currencyCode: String?
    public let updatedAt: String?
    public let historyDays: Int?
    public let sessionTokens: Int?
    public let sessionCostUSD: Double?
    public let last30DaysTokens: Int?
    public let last30DaysCostUSD: Double?
    public let daily: [RawDaily]?
    public let totals: RawTotals?
    public let error: RawError?
}

public struct RawDaily: Decodable, Sendable {
    public let date: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
    public let totalTokens: Int?
    public let totalCost: Double?
    public let modelsUsed: [String]?
    public let modelBreakdowns: [RawModelBreakdown]?
}

public struct RawModelBreakdown: Decodable, Sendable {
    public let modelName: String?
    public let cost: Double?
    public let totalTokens: Int?
}

public struct RawTotals: Decodable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
    public let totalTokens: Int?
    public let totalCost: Double?
}

// MARK: - Framing

/// Parses codexbar stdout into envelopes. Tries a JSON array first (the observed
/// framing), then falls back to newline-delimited objects, so we stay robust if a
/// future codexbar version switches framing. Returns `[]` for empty input.
public enum RawEngineDecoder {
    public static func usageEnvelopes(from data: Data) throws -> [RawUsageEnvelope] {
        try envelopes(from: data)
    }

    public static func costEnvelopes(from data: Data) throws -> [RawCostEnvelope] {
        try envelopes(from: data)
    }

    private static func envelopes<T: Decodable>(from data: Data) throws -> [T] {
        let trimmed = data.trimmedJSON()
        guard !trimmed.isEmpty else { return [] }
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([T].self, from: trimmed) {
            return array
        }
        if let single = try? decoder.decode(T.self, from: trimmed) {
            return [single]
        }
        // NDJSON fallback: decode each non-empty line independently, skipping any
        // line that fails so one malformed record never drops the rest.
        var results: [T] = []
        for line in trimmed.split(separator: UInt8(ascii: "\n")) {
            let lineData = Data(line)
            guard !lineData.trimmedJSON().isEmpty else { continue }
            if let obj = try? decoder.decode(T.self, from: lineData) {
                results.append(obj)
            }
        }
        if results.isEmpty {
            // Surface a real failure rather than silently returning nothing.
            throw RawDecodeError.unparseable
        }
        return results
    }
}

public enum RawDecodeError: Error, Sendable {
    case unparseable
}

private extension Data {
    /// Drops leading/trailing ASCII whitespace so stray newlines don't defeat the
    /// array-vs-NDJSON heuristic.
    func trimmedJSON() -> Data {
        let ws: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        var start = startIndex
        var end = endIndex
        while start < end, ws.contains(self[start]) { start = index(after: start) }
        while end > start, ws.contains(self[index(before: end)]) { end = index(before: end) }
        return subdata(in: start..<end)
    }
}
