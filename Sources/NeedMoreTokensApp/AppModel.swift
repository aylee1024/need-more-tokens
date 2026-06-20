import AppKit
import Foundation
import OSLog
import Security
import SwiftUI
import WidgetKit
import NeedMoreTokensKit

private let log = Logger(subsystem: "com.aylee1024.needmoretokens", category: "AppModel")

enum CodexResetMode: Equatable {
    case unavailable
    case deepLink(URL)
}

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
    private(set) var codexResetMode: CodexResetMode

    /// Seconds between automatic refreshes.
    var refreshInterval: TimeInterval = 120

    private var dataSource: ProviderDataSource
    private var loop: Task<Void, Never>?
    /// The last successful reading, kept so a price-override change can re-price the cards
    /// instantly without re-spawning codexbar.
    private var lastFetch: ProviderFetch?

    /// True while a user-initiated Keychain grant is in flight (interaction is briefly
    /// permitted). The periodic refresh pauses so it can't race the grant dialog.
    private(set) var isSeeding = false

    init(dataSource: ProviderDataSource? = nil) {
        // Keystone: a background Keychain read must never present the legacy "allow access"
        // dialog. Disabling Keychain UI process-wide makes such a read fail cleanly
        // (errSecAuthFailed) instead of prompting — verified on macOS 26. Interaction is
        // re-permitted only briefly, by an explicit user action (enableNativeKeychainAccess).
        KeychainInteraction.disableBackgroundPrompts()
        self.codexResetMode = AppModel.resolveCodexResetMode()
        self.dataSource = dataSource ?? Self.makeDataSourceFromDefaults()
    }

    var entries: [WidgetSnapshot.Entry] { snapshot?.entries ?? [] }
    var lowestRemainingPercent: Double? { snapshot?.lowestRemainingPercent }
    var codexResetCount: Int? { entries.first { $0.provider == .codex }?.resetCount }

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

    /// One-time, user-initiated grant of native Keychain access. Briefly permits the
    /// Keychain dialog, does a throwaway read of each Keychain-backed item so the user can
    /// click "Always Allow" once per item (the tokens are discarded — the durable ACL grant
    /// is the point), then restores the background-safe state and refreshes. Runs the
    /// blocking reads off the main actor so the UI stays responsive while the dialog is up.
    func enableNativeKeychainAccess() async {
        guard !isSeeding else { return }
        isSeeding = true
        // Close the race against an already-in-flight background fetch: `isSeeding` (just set)
        // blocks any NEW fetch (performFetch guards on it), so wait for a current one to drain
        // BEFORE enabling Keychain interaction. That in-flight read then completes with
        // interaction still disabled (no prompt), and nothing reads the Keychain while the
        // grant window below is open. The loop converges because no new fetch can start.
        while isRefreshing {
            if Task.isCancelled { isSeeding = false; return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // The grant reads block until the user dismisses the dialog — an unbounded wait.
        // Run them on a dedicated dispatch queue, NOT the Swift cooperative pool, so a slow
        // click can't starve a cooperative thread. The main actor stays free awaiting the
        // continuation (isSeeding pauses the periodic refresh meanwhile).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                KeychainInteraction.withInteractionAllowed {
                    let reader = SystemKeychainReader()
                    _ = try? reader.readGenericPassword(service: ClaudeCredentialLoader.defaultService,
                                                        account: ClaudeCredentialLoader.defaultAccount)
                    _ = try? reader.readGenericPassword(service: CredentialStore.defaultGeminiKeychainService,
                                                        account: CredentialStore.defaultGeminiKeychainAccount)
                }
                continuation.resume()
            }
        }
        // Clear the guard BEFORE refreshing so the immediate post-grant fetch is not
        // skipped by performFetch's `!isSeeding` check.
        isSeeding = false
        await refresh()
    }

    private func performFetch() async {
        // Don't read the Keychain while a grant dialog is up (interaction is permitted);
        // the periodic refresh resumes once the user has finished granting.
        guard !isSeeding else { return }
        // Belt-and-suspenders: keep background prompts disabled even if a prior grant left
        // interaction toggled (e.g. a crash mid-grant).
        KeychainInteraction.disableBackgroundPrompts()
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
            lastError = "Refresh failed (\(type(of: error)))"
            log.error("refresh: error \(String(describing: type(of: error)), privacy: .public)")
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

    func openCodexResetUI() {
        guard case .deepLink(let url) = codexResetMode else { return }
        NSWorkspace.shared.open(url)
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

    private static func resolveCodexResetMode() -> CodexResetMode {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              isCodexSignedByOpenAI(appURL: url) else {
            return .unavailable
        }
        return .deepLink(url)
    }

    /// Verifies the resolved app is validly signed, Apple-anchored, has the expected
    /// bundle id, and is signed by OpenAI's Team Identifier (verified on-machine:
    /// "Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)"). Fails closed so a
    /// hijacked LaunchServices registration cannot make NMT launch attacker code.
    private static func isCodexSignedByOpenAI(appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        let reqText = "identifier \"com.openai.codex\" and anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqText, [], &requirement) == errSecSuccess,
              let req = requirement else { return false }
        // Validate ALL architectures AND nested code (frameworks/helpers) — without
        // kSecCSCheckNestedCode a tampered nested dylib in an otherwise-signed bundle
        // would pass. Verified deep+strict on-machine against the real Codex.app.
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode))
        return SecStaticCodeCheckValidityWithErrors(code, flags, req, nil) == errSecSuccess
    }
}
