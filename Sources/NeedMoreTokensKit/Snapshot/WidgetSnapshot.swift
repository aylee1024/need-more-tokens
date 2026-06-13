import Foundation

/// Compact state the app writes and the widget reads, through the App Group
/// container. It carries exactly what the menu bar and widgets render — the two
/// (or three) windows, the cost summary, credits, and per-provider state — but not
/// the full daily history (that stays in the ledger DB). Being the *same* type in
/// both targets means the app and widget can never drift.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var engineState: EngineState
    public var entries: [Entry]

    public init(schemaVersion: Int = WidgetSnapshot.currentSchemaVersion,
                generatedAt: Date,
                engineState: EngineState,
                entries: [Entry]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.engineState = engineState
        self.entries = entries
    }

    /// Overall health of the last refresh, so the widget can show a clear empty/error
    /// state instead of a confusing blank.
    public enum EngineState: String, Codable, Sendable {
        case ok
        case binaryMissing
        case error
        case loading
    }

    public enum ProviderState: String, Codable, Sendable {
        case live
        case stale
        case disabled
        case error
        case loading
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var provider: Provider
        public var planName: String?
        public var accountEmail: String?
        public var windows: [RateWindow]
        public var extraWindows: [RateWindow]
        public var cost: CostSummary
        public var monthlyPriceUSD: Double?
        public var creditsRemaining: Double?
        public var exactMonthlyCap: MonetaryCap?
        public var state: ProviderState
        public var errorMessage: String?
        public var updatedAt: Date?
        public var resetCount: Int?

        public init(provider: Provider, planName: String?, accountEmail: String?, windows: [RateWindow],
                    extraWindows: [RateWindow] = [], cost: CostSummary, monthlyPriceUSD: Double? = nil,
                    creditsRemaining: Double?, exactMonthlyCap: MonetaryCap?,
                    state: ProviderState, errorMessage: String? = nil, updatedAt: Date?,
                    resetCount: Int? = nil) {
            self.provider = provider
            self.planName = planName
            self.accountEmail = accountEmail
            self.windows = windows
            self.extraWindows = extraWindows
            self.cost = cost
            self.monthlyPriceUSD = monthlyPriceUSD
            self.creditsRemaining = creditsRemaining
            self.exactMonthlyCap = exactMonthlyCap
            self.state = state
            self.errorMessage = errorMessage
            self.updatedAt = updatedAt
            self.resetCount = resetCount
        }

        /// Decode-tolerant: additive fields use `decodeIfPresent` so a snapshot written
        /// by an older build (missing a key) still loads with sensible defaults,
        /// instead of throwing and silently emptying the widget. Encoding stays
        /// synthesized from these keys.
        enum CodingKeys: String, CodingKey {
            case provider, planName, accountEmail, windows, extraWindows, cost
            case monthlyPriceUSD, creditsRemaining, exactMonthlyCap, state, errorMessage, updatedAt, resetCount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = try c.decode(Provider.self, forKey: .provider)
            planName = try c.decodeIfPresent(String.self, forKey: .planName)
            accountEmail = try c.decodeIfPresent(String.self, forKey: .accountEmail)
            windows = try c.decodeIfPresent([RateWindow].self, forKey: .windows) ?? []
            extraWindows = try c.decodeIfPresent([RateWindow].self, forKey: .extraWindows) ?? []
            cost = try c.decode(CostSummary.self, forKey: .cost)
            monthlyPriceUSD = try c.decodeIfPresent(Double.self, forKey: .monthlyPriceUSD)
            creditsRemaining = try c.decodeIfPresent(Double.self, forKey: .creditsRemaining)
            exactMonthlyCap = try c.decodeIfPresent(MonetaryCap.self, forKey: .exactMonthlyCap)
            state = try c.decodeIfPresent(ProviderState.self, forKey: .state) ?? .loading
            errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
            resetCount = try c.decodeIfPresent(Int.self, forKey: .resetCount)
        }

        /// Window closest to its limit (incl. extras) — drives the compact glance.
        public var tightestWindow: RateWindow? {
            (windows + extraWindows).min(by: { $0.remainingPercent < $1.remainingPercent })
        }
    }

    public struct CostSummary: Codable, Sendable, Equatable {
        public var isAvailable: Bool
        public var isEstimated: Bool
        public var currencyCode: String
        public var cycleCostUSD: Double?
        public var lifetimeCostUSD: Double?
        public var unavailableReason: String?

        public init(isAvailable: Bool, isEstimated: Bool, currencyCode: String,
                    cycleCostUSD: Double?, lifetimeCostUSD: Double?, unavailableReason: String?) {
            self.isAvailable = isAvailable
            self.isEstimated = isEstimated
            self.currencyCode = currencyCode
            self.cycleCostUSD = cycleCostUSD
            self.lifetimeCostUSD = lifetimeCostUSD
            self.unavailableReason = unavailableReason
        }
    }

    /// The lowest remaining-percent across all entries' windows — the single number
    /// the menu-bar icon can show ("am I about to run out?"). Nil if no windows.
    public var lowestRemainingPercent: Double? {
        entries.compactMap(\.tightestWindow?.remainingPercent).min()
    }
}
