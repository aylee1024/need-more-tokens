import Foundation

/// The three providers Need More Tokens surfaces. Raw provider strings from the
/// engine are normalized into these (see `Provider.normalized`).
public enum Provider: String, CaseIterable, Codable, Sendable, Hashable {
    case claude
    case codex
    case gemini

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }

    /// The codexbar `--source` to force for this provider's usage fetch, or nil to
    /// let codexbar pick (its `auto` default). Codex's `auto` tries the OpenAI web
    /// dashboard first, which was measured at 162.9s on this machine (2026-06-12) and
    /// blew past the 35s usage timeout; the `cli` source returns the same data —
    /// credits, 5-hour, weekly, plan — in 1.2s, so we pin Codex to `cli`. Claude is
    /// left on `auto` because its web source supplies the monthly spend cap the CLI
    /// source omits; Gemini has no fast/slow split worth overriding.
    public var usageSourceOverride: String? {
        switch self {
        case .codex: "cli"
        case .claude, .gemini: nil
        }
    }

    /// Maps the engine's provider id (and a few aliases) to a known provider.
    /// Returns nil for anything we don't surface, so a future codexbar provider is
    /// dropped cleanly instead of misrendered.
    public static func normalized(_ raw: String?) -> Provider? {
        switch raw?.lowercased() {
        case "claude", "claude-code", "anthropic": .claude
        case "codex", "openai": .codex
        case "gemini", "google": .gemini
        default: nil
        }
    }
}

/// A rate-limit window, labeled by its real period. The engine reports windows by
/// `windowMinutes`, which differ per provider — Codex/Claude use 5-hour (300) and
/// weekly (10080); Gemini uses daily (1440). We never hardcode "5-hour/weekly"
/// onto a provider that does not report it.
public struct RateWindow: Sendable, Codable, Equatable {
    /// Display name for this window. Grounded in codexbar's documented mapping:
    /// for Gemini the windows are per-model (Pro / Flash / Flash Lite); for Claude
    /// the duplicate weekly is the model-specific (Opus) weekly cap. Falls back to
    /// the period label.
    public let label: String
    public let period: Period
    public let windowMinutes: Int
    public let usedPercent: Double
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(label: String, period: Period, windowMinutes: Int, usedPercent: Double, resetsAt: Date?, resetDescription: String?) {
        self.label = label
        self.period = period
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }

    public enum Period: Sendable, Codable, Equatable {
        case fiveHour      // 300
        case daily         // 1440
        case weekly        // 10080
        case other(minutes: Int)

        public init(windowMinutes: Int) {
            switch windowMinutes {
            case 300: self = .fiveHour
            case 1440: self = .daily
            case 10080: self = .weekly
            default: self = .other(minutes: windowMinutes)
            }
        }

        /// Short, human label. For unusual windows, renders the duration honestly
        /// (e.g. "3h", "2d", "90m") rather than inventing a named period.
        public var shortLabel: String {
            switch self {
            case .fiveHour: "5-hour"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .other(let minutes):
                if minutes % 1440 == 0 { "\(minutes / 1440)d" }
                else if minutes % 60 == 0 { "\(minutes / 60)h" }
                else { "\(minutes)m" }
            }
        }
    }
}

/// An exact monetary cap reported by the provider's own dashboard (Claude exposes
/// a "Monthly cap" with used/limit). This is real spend, not an estimate — kept
/// separate from the estimated token×price cost so the two are never conflated.
public struct MonetaryCap: Sendable, Codable, Equatable {
    public let used: Double
    public let limit: Double
    public let currencyCode: String
    public let periodLabel: String

    public init(used: Double, limit: Double, currencyCode: String, periodLabel: String) {
        self.used = used
        self.limit = limit
        self.currencyCode = currencyCode
        self.periodLabel = periodLabel
    }
}

/// Usage for one provider: its rate windows plus account/plan metadata.
public struct ProviderUsage: Sendable, Codable, Equatable {
    public let provider: Provider
    public let windows: [RateWindow]        // primary, secondary, tertiary that are present, in order
    public let extraWindows: [RateWindow]   // engine extraRateWindows (e.g. Claude "Daily Routines")
    public let accountEmail: String?
    public let planName: String?            // engine "loginMethod": "Claude Max", "Pro 5x", "Paid"
    public let creditsRemaining: Double?
    public let exactMonthlyCap: MonetaryCap? // Claude's extra-usage cap (used/limit), when present
    public let statusIndicator: String?
    public let updatedAt: Date?

    public init(provider: Provider, windows: [RateWindow], extraWindows: [RateWindow] = [],
                accountEmail: String?, planName: String?, creditsRemaining: Double?,
                exactMonthlyCap: MonetaryCap?, statusIndicator: String?, updatedAt: Date?) {
        self.provider = provider
        self.windows = windows
        self.extraWindows = extraWindows
        self.accountEmail = accountEmail
        self.planName = planName
        self.creditsRemaining = creditsRemaining
        self.exactMonthlyCap = exactMonthlyCap
        self.statusIndicator = statusIndicator
        self.updatedAt = updatedAt
    }

    /// The window closest to exhausting — drives the menu-bar "lowest remaining"
    /// glance. Includes extra windows (e.g. Daily Routines) so an exhausted extra
    /// quota is never invisible. Nil when the provider reports no windows.
    public var tightestWindow: RateWindow? {
        (windows + extraWindows).min(by: { $0.remainingPercent < $1.remainingPercent })
    }
}

/// One day's cost for a provider (the unit the lifetime ledger accumulates).
public struct DailyCost: Sendable, Codable, Equatable {
    public let dayKey: String          // "YYYY-MM-DD" as the engine emits (provider-local)
    public let totalTokens: Int
    public let totalCostUSD: Double

    public init(dayKey: String, totalTokens: Int, totalCostUSD: Double) {
        self.dayKey = dayKey
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
    }
}

/// Cost for one provider. `isAvailable` is false where the engine cannot compute
/// cost (Gemini today), so the UI shows an honest "n/a" instead of a fake $0.
/// `isEstimated` is true when the figure comes from local token logs × public
/// prices (engine source "local") rather than an exact billing source.
public struct ProviderCost: Sendable, Codable, Equatable {
    public let provider: Provider
    public let isAvailable: Bool
    public let unavailableReason: String?
    public let isEstimated: Bool
    public let currencyCode: String
    public let sessionCostUSD: Double?
    public let last30DaysCostUSD: Double?
    public let cycleCostUSD: Double?        // summed from daily[] >= the cycle anchor
    public let lifetimeCostUSD: Double?     // filled from our ledger; nil before reconciliation
    public let daily: [DailyCost]
    public let updatedAt: Date?

    public init(provider: Provider, isAvailable: Bool, unavailableReason: String?, isEstimated: Bool,
                currencyCode: String, sessionCostUSD: Double?, last30DaysCostUSD: Double?,
                cycleCostUSD: Double?, lifetimeCostUSD: Double?, daily: [DailyCost], updatedAt: Date?) {
        self.provider = provider
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.isEstimated = isEstimated
        self.currencyCode = currencyCode
        self.sessionCostUSD = sessionCostUSD
        self.last30DaysCostUSD = last30DaysCostUSD
        self.cycleCostUSD = cycleCostUSD
        self.lifetimeCostUSD = lifetimeCostUSD
        self.daily = daily
        self.updatedAt = updatedAt
    }

    /// A cost result for a provider the engine cannot price (e.g. Gemini).
    public static func unavailable(_ provider: Provider, reason: String) -> ProviderCost {
        ProviderCost(provider: provider, isAvailable: false, unavailableReason: reason, isEstimated: false,
                     currencyCode: "USD", sessionCostUSD: nil, last30DaysCostUSD: nil, cycleCostUSD: nil,
                     lifetimeCostUSD: nil, daily: [], updatedAt: nil)
    }
}
