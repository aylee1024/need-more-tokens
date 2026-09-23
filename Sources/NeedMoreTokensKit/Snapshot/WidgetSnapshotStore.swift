import Foundation

/// Reads/writes the widget snapshot in the App Group container. The app writes
/// (atomically) after each refresh; the widget only reads. Both go through here so
/// the file format and date strategy are defined in exactly one place.
///
/// `encode`/`decode` are the same wire format, exposed so the iCloud sync to the iPhone app
/// ships byte-compatible payloads.
public enum WidgetSnapshotStore {
    public static func load(from url: URL = AppGroupContainer.snapshotURL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    @discardableResult
    public static func save(_ snapshot: WidgetSnapshot, to url: URL = AppGroupContainer.snapshotURL) -> Bool {
        guard let data = encode(snapshot) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// The snapshot's wire form: ISO-8601 dates, sorted keys (so equal snapshots encode to
    /// equal bytes).
    public static func encode(_ snapshot: WidgetSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }

    /// Decodes a snapshot, or nil if it is malformed or from a different schema version.
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.schemaVersion == WidgetSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }
}

extension WidgetSnapshot {
    /// Builds a snapshot from an engine fetch for the enabled providers. Lifetime
    /// costs come from the ledger (empty until milestone 4); when absent, falls back
    /// to the fetch's own lifetime value (nil today).
    public static func build(from fetch: ProviderFetch,
                             enabledProviders: [Provider],
                             lifetimeCosts: [Provider: Double] = [:],
                             subscriptionOverrides: [Provider: Double] = [:],
                             engineState: EngineState = .ok) -> WidgetSnapshot {
        let entries: [Entry] = enabledProviders.map { provider in
            let usage = fetch.usages[provider]
            let cost = fetch.costs[provider]
            let state: ProviderState = {
                if usage != nil { return .live }
                if fetch.usageErrors[provider] != nil { return .error }
                return .loading
            }()
            let costSummary = CostSummary(
                isAvailable: cost?.isAvailable ?? false,
                isEstimated: cost?.isEstimated ?? false,
                currencyCode: cost?.currencyCode ?? "USD",
                cycleCostUSD: cost?.cycleCostUSD,
                lifetimeCostUSD: lifetimeCosts[provider] ?? cost?.lifetimeCostUSD,
                unavailableReason: cost?.unavailableReason
            )
            // A non-positive override means "no override" — ignore it here too, not just
            // in the loader, so this public builder is robust to any caller.
            let price = subscriptionOverrides[provider].flatMap { $0 > 0 ? $0 : nil }
                ?? Subscriptions.defaultMonthlyUSD(for: provider, planName: usage?.planName)
            return Entry(
                provider: provider,
                planName: usage?.planName,
                accountEmail: usage?.accountEmail,
                windows: usage?.windows ?? [],
                extraWindows: usage?.extraWindows ?? [],
                cost: costSummary,
                monthlyPriceUSD: price,
                creditsRemaining: usage?.creditsRemaining,
                exactMonthlyCap: usage?.exactMonthlyCap,
                state: state,
                errorMessage: fetch.usageErrors[provider],
                updatedAt: usage?.updatedAt,
                resetCount: usage?.resetCount,
                requiresSignIn: fetch.providersNeedingSignIn.contains(provider)
            )
        }
        return WidgetSnapshot(generatedAt: fetch.generatedAt, engineState: engineState, entries: entries)
    }
}
