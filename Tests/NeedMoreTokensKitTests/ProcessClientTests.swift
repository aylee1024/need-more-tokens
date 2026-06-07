import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("ProcessClient spawn / drain / timeout")
struct ProcessClientTests {
    let sh = URL(fileURLWithPath: "/bin/sh")

    @Test func returnsStdoutOnSuccess() async throws {
        let data = try await ProcessClient().run(executable: sh, arguments: ["-c", "printf 'hello world'"])
        #expect(String(decoding: data, as: UTF8.self) == "hello world")
    }

    @Test func mapsExitCodesToErrors() async {
        await #expect(throws: EngineError.providerMissing) {
            try await ProcessClient().run(executable: sh, arguments: ["-c", "exit 2"])
        }
        await #expect(throws: EngineError.timeout) {  // exit 4 maps to timeout
            try await ProcessClient().run(executable: sh, arguments: ["-c", "exit 4"])
        }
        await #expect(throws: EngineError.self) {     // exit 1 → unexpected
            try await ProcessClient().run(executable: sh, arguments: ["-c", "echo oops 1>&2; exit 1"])
        }
    }

    @Test func badOutputCarriesStderr() async {
        do {
            _ = try await ProcessClient().run(executable: sh, arguments: ["-c", "echo 'parse failed' 1>&2; exit 3"])
            Issue.record("expected throw")
        } catch let error as EngineError {
            guard case let .badOutput(message) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(message.contains("parse failed"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func missingBinaryThrowsBinaryMissing() async {
        await #expect(throws: EngineError.binaryMissing) {
            try await ProcessClient().run(executable: URL(fileURLWithPath: "/nonexistent/codexbar"), arguments: [])
        }
    }

    @Test func timeoutKillsProcessAndThrows() async throws {
        let start = Date()
        await #expect(throws: EngineError.timeout) {
            try await ProcessClient().run(executable: sh, arguments: ["-c", "sleep 10"], timeout: 1)
        }
        // Should return shortly after the 1s deadline (+ up to 2s SIGKILL grace), not 10s.
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func drainsOutputLargerThanPipeBuffer() async throws {
        // 200 KB exceeds the ~64 KB pipe buffer; proves the concurrent drain avoids
        // the classic write-blocks-while-we-wait deadlock.
        let data = try await ProcessClient().run(
            executable: sh,
            arguments: ["-c", "yes a | head -c 200000"],
            timeout: 15
        )
        #expect(data.count == 200000)
    }
}

@Suite("WidgetSnapshot store + build")
struct WidgetSnapshotTests {
    @Test func roundTripsThroughDisk() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nmt-snap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let window = RateWindow(label: "5-hour", period: .fiveHour, windowMinutes: 300, usedPercent: 25,
                                resetsAt: Date(timeIntervalSince1970: 1_780_000_000), resetDescription: "soon")
        let entry = WidgetSnapshot.Entry(
            provider: .codex, planName: "prolite", accountEmail: "user@example.com",
            windows: [window],
            cost: .init(isAvailable: true, isEstimated: true, currencyCode: "USD",
                        cycleCostUSD: 12.5, lifetimeCostUSD: 99.9, unavailableReason: nil),
            creditsRemaining: 1000, exactMonthlyCap: nil, state: .live,
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let snapshot = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
                                      engineState: .ok, entries: [entry])

        #expect(WidgetSnapshotStore.save(snapshot, to: tmp))
        let loaded = try #require(WidgetSnapshotStore.load(from: tmp))
        #expect(loaded == snapshot)
        #expect(loaded.lowestRemainingPercent == 75)
    }

    @Test func loadReturnsNilForMissingFile() {
        let missing = URL(fileURLWithPath: "/nonexistent/snap.json")
        #expect(WidgetSnapshotStore.load(from: missing) == nil)
    }
}
