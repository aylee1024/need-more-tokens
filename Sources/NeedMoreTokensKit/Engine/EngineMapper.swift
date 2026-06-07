import Foundation

/// Turns tolerant `Raw*` envelopes into clean domain values. This is the single
/// place that knows codexbar's wire shape; everything above it sees only domain
/// types, so an upstream JSON change is absorbed here.
///
/// Mapping facts encoded (verified against codexbar 0.32.0 output, 2026-06-06):
/// - Windows are labeled by real `windowMinutes` (Codex/Claude 300+10080; Gemini
///   3×1440). We never force "5-hour/weekly" onto a provider that doesn't report it.
/// - `cost.source == "local"` means the figure is an estimate (local tokens ×
///   public prices), flagged via `isEstimated`.
/// - Gemini cost is not produced by the engine ("cost is only supported for Claude
///   and Codex"): its cost envelope is an error / carries provider "cli", so it maps
///   to no provider here and the caller fills `ProviderCost.unavailable`.
public enum EngineMapper {

    public struct UsageMapping: Sendable, Equatable {
        public var usages: [Provider: ProviderUsage]
        public var errors: [Provider: String]
    }

    public static func mapUsage(_ envelopes: [RawUsageEnvelope]) -> UsageMapping {
        var usages: [Provider: ProviderUsage] = [:]
        var errors: [Provider: String] = [:]
        for env in envelopes {
            guard let provider = Provider.normalized(env.provider) else { continue }
            if let error = env.error {
                errors[provider] = error.message ?? "Engine reported an error"
                continue
            }
            guard let usage = env.usage else {
                errors[provider] = "No usage data returned"
                continue
            }
            let windows = [usage.primary, usage.secondary, usage.tertiary]
                .enumerated()
                .compactMap { window(from: $1, provider: provider, position: $0) }
            let extraWindows = (usage.extraRateWindows ?? []).compactMap(extraWindow(from:))
            usages[provider] = ProviderUsage(
                provider: provider,
                windows: windows,
                extraWindows: extraWindows,
                accountEmail: usage.accountEmail,
                planName: usage.loginMethod,
                creditsRemaining: env.credits?.remaining.flatMap { ($0.isFinite && $0 >= 0) ? $0 : nil },
                exactMonthlyCap: monetaryCap(from: usage.providerCost),
                statusIndicator: env.status?.indicator,
                updatedAt: parseDate(usage.updatedAt)
            )
        }
        return UsageMapping(usages: usages, errors: errors)
    }

    /// Maps cost envelopes for providers the engine can price. `cycleStartDayKey`
    /// is the inclusive "YYYY-MM-DD" start of the current billing cycle; the cycle
    /// figure sums `daily[]` on/after it. Providers absent here are filled as
    /// unavailable by the caller (which knows the full enabled set).
    public static func mapCost(_ envelopes: [RawCostEnvelope], cycleStartDayKey: String) -> [Provider: ProviderCost] {
        var result: [Provider: ProviderCost] = [:]
        for env in envelopes {
            guard env.error == nil, let provider = Provider.normalized(env.provider) else { continue }
            let daily: [DailyCost] = (env.daily ?? []).compactMap { raw in
                guard let dayKey = raw.date else { return nil }
                return DailyCost(dayKey: dayKey,
                                 totalTokens: max(0, raw.totalTokens ?? 0),
                                 totalCostUSD: sanitizeMoney(raw.totalCost))
            }
            let cycle = daily.filter { $0.dayKey >= cycleStartDayKey }
                .reduce(0.0) { $0 + $1.totalCostUSD }
            result[provider] = ProviderCost(
                provider: provider,
                isAvailable: true,
                unavailableReason: nil,
                isEstimated: (env.source ?? "").lowercased() == "local",
                currencyCode: env.currencyCode ?? "USD",
                sessionCostUSD: env.sessionCostUSD.map(sanitizeMoney),
                last30DaysCostUSD: env.last30DaysCostUSD.map(sanitizeMoney),
                cycleCostUSD: cycle,
                lifetimeCostUSD: nil,
                daily: daily,
                updatedAt: parseDate(env.updatedAt)
            )
        }
        return result
    }

    // MARK: - Helpers

    private static func window(from raw: RawWindow?, provider: Provider, position: Int) -> RateWindow? {
        guard let raw, let used = raw.usedPercent, let minutes = raw.windowMinutes else { return nil }
        return RateWindow(
            label: windowLabel(provider: provider, position: position, windowMinutes: minutes),
            period: RateWindow.Period(windowMinutes: minutes),
            windowMinutes: minutes,
            usedPercent: min(100, max(0, used)),
            resetsAt: parseDate(raw.resetsAt),
            resetDescription: raw.resetDescription
        )
    }

    /// Maps an `extraRateWindows` entry (e.g. Claude "Daily Routines") to a window,
    /// labeled by its engine-provided title.
    private static func extraWindow(from raw: RawExtraWindow?) -> RateWindow? {
        guard let raw, let window = raw.window, let used = window.usedPercent, let minutes = window.windowMinutes
        else { return nil }
        let title = raw.title?.isEmpty == false ? raw.title! : RateWindow.Period(windowMinutes: minutes).shortLabel
        return RateWindow(
            label: title,
            period: RateWindow.Period(windowMinutes: minutes),
            windowMinutes: minutes,
            usedPercent: min(100, max(0, used)),
            resetsAt: parseDate(window.resetsAt),
            resetDescription: window.resetDescription
        )
    }

    /// Display label for a window, grounded in codexbar's documented slot semantics:
    /// - Gemini windows are per-model quota buckets (primary=Pro, secondary=Flash,
    ///   tertiary=Flash Lite), the same buckets the CLI `/model` screen shows. They
    ///   are NOT the consumer Gemini app's "Usage limits" — that's a different product.
    /// - Claude maps five_hour→session, seven_day→Weekly, seven_day_opus/sonnet→a
    ///   model-specific weekly cap; we label that second weekly "Weekly · Opus".
    /// - Codex is labeled purely by period (5-hour / Weekly).
    static func windowLabel(provider: Provider, position: Int, windowMinutes: Int) -> String {
        switch provider {
        case .gemini:
            switch position {
            case 0: return "Pro"
            case 1: return "Flash"
            case 2: return "Flash Lite"
            default: return RateWindow.Period(windowMinutes: windowMinutes).shortLabel
            }
        case .claude:
            // codexbar collapses seven_day_opus/seven_day_sonnet into one slot. We
            // default to Sonnet (the active one for the typical Max account) and the
            // Claude direct-API path overrides this with the truly-active model.
            if windowMinutes == 10080, position >= 2 { return "Weekly · Sonnet" }
            return RateWindow.Period(windowMinutes: windowMinutes).shortLabel
        case .codex:
            return RateWindow.Period(windowMinutes: windowMinutes).shortLabel
        }
    }

    private static func monetaryCap(from raw: RawProviderCost?) -> MonetaryCap? {
        guard let raw, let used = raw.used, let limit = raw.limit else { return nil }
        return MonetaryCap(
            used: sanitizeMoney(used),
            limit: sanitizeMoney(limit),
            currencyCode: raw.currencyCode ?? "USD",
            periodLabel: raw.period ?? "Cap"
        )
    }

    /// Clamps a money value to a finite, non-negative number so a bad datum never
    /// poisons a sum or renders as "NaN".
    static func sanitizeMoney(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }

    /// Parses the engine's ISO8601 timestamps (with or without fractional seconds).
    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// The inclusive day-key marking the start of the monthly billing cycle that
    /// contains `date` (default anchor: the 1st). Callers may override the anchor
    /// day per provider in settings.
    public static func firstOfMonthDayKey(for date: Date, anchorDay: Int = 1, calendar: Calendar = .current) -> String {
        // Clamp to a day every month has, so we never form an invalid date.
        let clampedDay = max(1, min(anchorDay, 28))
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = clampedDay
        var start = calendar.date(from: comps) ?? date
        if start > date {
            // The anchor day hasn't arrived yet this month → the current cycle began
            // last month (otherwise the "cycle start" would be in the future and sum 0).
            start = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: start)
    }
}
