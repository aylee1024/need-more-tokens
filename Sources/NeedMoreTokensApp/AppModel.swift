import Foundation
import OSLog
import SwiftUI
import WidgetKit
import NeedMoreTokensKit

private let log = Logger(subsystem: "com.aylee1024.needmoretokens", category: "AppModel")

/// Owns the refresh loop and the latest snapshot the UI renders. Lives on the main
/// actor; the engine work hops off it inside `EngineAdapter`.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: WidgetSnapshot?
    private(set) var engineState: WidgetSnapshot.EngineState = .loading
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    /// Seconds between automatic refreshes.
    var refreshInterval: TimeInterval = 120

    private var dataSource: ProviderDataSource
    private var loop: Task<Void, Never>?
    /// The last successful reading, kept so a price-override change can re-price the cards
    /// instantly without re-spawning codexbar.
    private var lastFetch: ProviderFetch?

    init(dataSource: ProviderDataSource? = nil) {
        self.dataSource = dataSource ?? Self.makeDataSourceFromDefaults()
    }

    var entries: [WidgetSnapshot.Entry] { snapshot?.entries ?? [] }
    var lowestRemainingPercent: Double? { snapshot?.lowestRemainingPercent }

    /// Begins the periodic refresh loop (idempotent).
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.refreshInterval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func reloadDataSourceFromDefaults() {
        dataSource = Self.makeDataSourceFromDefaults()
    }

    /// Set when refresh() is called while one is already running, so the in-flight
    /// run loops once more. A settings change rebuilds the data source then asks for
    /// a refresh — without this, that request would be dropped and the new routing
    /// wouldn't show until the next timer tick.
    private var refreshQueued = false

    func refresh() async {
        if isRefreshing { refreshQueued = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            await performFetch()
        } while refreshQueued
    }

    private func performFetch() async {
        log.info("refresh: starting fetch")
        do {
            let dataSource = dataSource
            let fetch = try await dataSource.fetch()
            lastFetch = fetch
            let snap = WidgetSnapshot.build(from: fetch, enabledProviders: Provider.allCases,
                                            subscriptionOverrides: PriceOverrides.load())
            snapshot = snap
            engineState = .ok
            lastError = nil
            lastRefresh = Date()
            if WidgetSnapshotStore.save(snap) {
                WidgetCenter.shared.reloadAllTimelines()
                log.info("refresh: ok, \(snap.entries.count) entries")
            } else {
                // Don't reload the widget onto a snapshot we failed to persist.
                log.error("refresh: snapshot save failed; widget left on previous data")
            }
        } catch let error as EngineError {
            engineState = (error == .binaryMissing) ? .binaryMissing : .error
            lastError = error.userMessage
            log.error("refresh: engine error \(error.userMessage, privacy: .public)")
        } catch {
            engineState = .error
            lastError = "\(error)"
            log.error("refresh: error \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-price the visible cards from the last successful reading when a subscription
    /// override changes — no codexbar re-spawn, so the change shows instantly. A no-op
    /// until the first successful fetch.
    func applyPriceOverrides() {
        guard let lastFetch else { return }
        let snap = WidgetSnapshot.build(from: lastFetch, enabledProviders: Provider.allCases,
                                        subscriptionOverrides: PriceOverrides.load(),
                                        engineState: engineState)
        snapshot = snap
        // Persist so the widget picks the new price up on its next reload. We deliberately
        // do NOT reloadAllTimelines() here: WidgetKit budgets reloads, and the periodic
        // refresh already reloads within the cycle — re-pricing per edit must not spend it.
        WidgetSnapshotStore.save(snap)
    }

    private static func makeDataSourceFromDefaults(defaults: UserDefaults = .standard) -> ProviderDataSource {
        // Snapshot the policies into a Sendable dictionary up front so the routing
        // closure captures only Sendable state — UserDefaults is not Sendable and
        // cannot be captured by the @Sendable policy closure under Swift 6.
        let policies = Dictionary(uniqueKeysWithValues: Provider.allCases.map {
            ($0, NativeMigrationFlags.policy(for: $0, in: defaults))
        })
        let fallbackOnError = NativeMigrationFlags.fallbackOnError(in: defaults)
        return RoutingProviderDataSource(
            native: NativeProviderDataSource(),
            codexbar: EngineAdapter(),
            policy: { policies[$0] ?? .auto },
            fallbackOnError: fallbackOnError
        )
    }
}
