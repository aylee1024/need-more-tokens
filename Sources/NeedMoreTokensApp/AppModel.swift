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

    private let adapter = EngineAdapter()
    private var loop: Task<Void, Never>?

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

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        log.info("refresh: starting fetch")
        do {
            let fetch = try await adapter.fetch()
            let snap = WidgetSnapshot.build(from: fetch, enabledProviders: Provider.allCases)
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
}
