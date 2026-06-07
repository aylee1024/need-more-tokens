import Foundation

/// The app's single entry point to the codexbar engine. Locates the binary, then
/// fetches each provider **independently and concurrently** (usage + cost per
/// provider). Independence is deliberate: a single `--provider all` call couples
/// the providers' fates, so one provider hanging (e.g. Claude waiting on a Keychain
/// prompt) or being slow would stall or lose the others. Per-provider calls give
/// each its own timeout and let the menu bar show whatever succeeded.
///
/// Usage is required per provider; cost is best-effort (and Gemini, which the engine
/// cannot price, resolves to `ProviderCost.unavailable`). Lifetime cost is filled
/// later by the ledger.
public struct EngineAdapter: Sendable {
    public let locator: BinaryLocator
    public let process: ProcessClient
    public var usageTimeout: TimeInterval
    public var costTimeout: TimeInterval
    /// Cap on concurrently-spawned codexbar processes. Real testing showed that
    /// running all three at once makes one provider (Codex) contend and time out;
    /// capping at 2 avoids that while keeping most of the parallel speedup.
    public var maxConcurrency: Int
    /// Whether to spawn `codexbar cost`. Off by default: the UI shows the monthly
    /// subscription + credits, not the estimated token cost, so the (extra, slower)
    /// cost spawns would be wasted work and add process contention. The lifetime
    /// ledger (a later milestone) will turn this on when it actually consumes cost.
    public var fetchCost: Bool

    public init(overridePath: String? = nil,
                process: ProcessClient = ProcessClient(),
                usageTimeout: TimeInterval = 35,
                costTimeout: TimeInterval = 45,
                maxConcurrency: Int = 2,
                fetchCost: Bool = false) {
        self.locator = BinaryLocator(overridePath: overridePath)
        self.process = process
        self.usageTimeout = usageTimeout
        self.costTimeout = costTimeout
        self.maxConcurrency = max(1, maxConcurrency)
        self.fetchCost = fetchCost
    }

    public struct Fetch: Sendable, Equatable {
        public var usages: [Provider: ProviderUsage]
        public var usageErrors: [Provider: String]
        public var costs: [Provider: ProviderCost]
        public var generatedAt: Date

        public func usage(for provider: Provider) -> ProviderUsage? { usages[provider] }
        public func cost(for provider: Provider) -> ProviderCost? { costs[provider] }
    }

    /// Fetches all `providers` concurrently. Throws `EngineError.binaryMissing` only
    /// when codexbar itself can't be found; any per-provider failure is captured in
    /// `usageErrors` / an unavailable cost, never thrown.
    public func fetch(providers: [Provider] = Provider.allCases,
                      cycleAnchorDay: Int = 1,
                      now: Date = Date()) async throws -> Fetch {
        let binary = try await resolveBinary()
        let cycleStart = EngineMapper.firstOfMonthDayKey(for: now, anchorDay: cycleAnchorDay)

        let limit = maxConcurrency
        let partials = await withTaskGroup(of: ProviderPartial.self) { group in
            var iterator = providers.makeIterator()
            var started = 0
            while started < limit, let provider = iterator.next() {
                group.addTask { await self.fetchOne(provider, binary: binary, cycleStart: cycleStart) }
                started += 1
            }
            var collected: [ProviderPartial] = []
            while let partial = await group.next() {
                collected.append(partial)
                if let provider = iterator.next() {
                    group.addTask { await self.fetchOne(provider, binary: binary, cycleStart: cycleStart) }
                }
            }
            return collected
        }

        var usages: [Provider: ProviderUsage] = [:]
        var usageErrors: [Provider: String] = [:]
        var costs: [Provider: ProviderCost] = [:]
        for partial in partials {
            if let usage = partial.usage { usages[partial.provider] = usage }
            if let error = partial.usageError { usageErrors[partial.provider] = error }
            costs[partial.provider] = partial.cost
        }
        return Fetch(usages: usages, usageErrors: usageErrors, costs: costs, generatedAt: now)
    }

    private struct ProviderPartial: Sendable {
        let provider: Provider
        let usage: ProviderUsage?
        let usageError: String?
        let cost: ProviderCost
    }

    private func fetchOne(_ provider: Provider, binary: URL, cycleStart: String) async -> ProviderPartial {
        var usage: ProviderUsage?
        var usageError: String?
        do {
            let data = try await process.run(
                executable: binary,
                arguments: ["usage", "--format", "json", "--provider", provider.rawValue, "--no-color"],
                timeout: usageTimeout
            )
            let mapping = EngineMapper.mapUsage(try RawEngineDecoder.usageEnvelopes(from: data))
            usage = mapping.usages[provider]
            usageError = mapping.errors[provider] ?? (usage == nil ? "No usage data returned" : nil)
        } catch let error as EngineError {
            usageError = Self.describe(error, provider: provider)
        } catch {
            usageError = "\(error)"
        }

        var cost: ProviderCost?
        var costFailure: String?
        if fetchCost, Self.engineCanPriceCost(provider) {
            do {
                let data = try await process.run(
                    executable: binary,
                    arguments: ["cost", "--format", "json", "--provider", provider.rawValue, "--no-color"],
                    timeout: costTimeout
                )
                if let envelopes = try? RawEngineDecoder.costEnvelopes(from: data) {
                    cost = EngineMapper.mapCost(envelopes, cycleStartDayKey: cycleStart)[provider]
                } else {
                    costFailure = "Unreadable cost output"
                }
            } catch let error as EngineError {
                costFailure = Self.describe(error, provider: provider)
            } catch {
                costFailure = "\(error)"
            }
        }
        return ProviderPartial(
            provider: provider,
            usage: usage,
            usageError: usageError,
            cost: cost ?? .unavailable(provider, reason: costFailure ?? Self.costUnavailableReason(provider))
        )
    }

    private func resolveBinary() async throws -> URL {
        if let url = locator.locate() { return url }
        if let url = await locator.locateViaLoginShell(runner: process) { return url }
        throw EngineError.binaryMissing
    }

    /// The engine prices Claude and Codex (local token logs × prices); Gemini is not
    /// supported, so we don't even spawn a cost call for it.
    static func engineCanPriceCost(_ provider: Provider) -> Bool {
        provider != .gemini
    }

    static func costUnavailableReason(_ provider: Provider) -> String {
        switch provider {
        case .gemini: "The engine does not compute Gemini cost (only Claude and Codex)."
        default: "Cost is unavailable for \(provider.displayName)."
        }
    }

    static func describe(_ error: EngineError, provider: Provider) -> String {
        switch error {
        case .binaryMissing: "codexbar not found"
        case .providerMissing: "\(provider.displayName) source not available"
        case .badOutput: "Unreadable engine output"
        case .timeout: "\(provider.displayName) timed out (Keychain prompt?)"
        case .unexpected(let message): message.isEmpty ? "Unexpected engine error" : message
        }
    }
}
