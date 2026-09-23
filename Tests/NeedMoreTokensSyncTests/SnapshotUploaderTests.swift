import Foundation
import Testing
import NeedMoreTokensKit
@testable import NeedMoreTokensSync

/// In-memory stand-in for the user's private CloudKit database.
private actor FakeCloudStore: SnapshotCloudStoring {
    private(set) var uploads: [CloudSnapshotRecord] = []
    var failNext = false

    struct Boom: Error {}

    func setFailNext(_ value: Bool) { failNext = value }

    func upload(_ record: CloudSnapshotRecord) async throws {
        if failNext { failNext = false; throw Boom() }
        uploads.append(record)
    }

    func downloadLatest() async throws -> CloudSnapshotRecord? { uploads.last }
}

private func snapshot(usedPercent: Double, readAt: Date) -> WidgetSnapshot {
    let window = RateWindow(label: "5-hour", period: .fiveHour, windowMinutes: 300,
                            usedPercent: usedPercent,
                            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                            resetDescription: nil)
    let entry = WidgetSnapshot.Entry(
        provider: .claude, planName: "Max", accountEmail: nil, windows: [window],
        cost: .init(isAvailable: false, isEstimated: false, currencyCode: "USD",
                    cycleCostUSD: nil, lifetimeCostUSD: nil, unavailableReason: nil),
        creditsRemaining: nil, exactMonthlyCap: nil, state: .live, updatedAt: readAt)
    return WidgetSnapshot(generatedAt: readAt, engineState: .ok, entries: [entry])
}

@Suite("Mac → iPhone snapshot upload policy")
struct SnapshotUploaderTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func firstSnapshotUploads() async {
        let store = FakeCloudStore()
        let uploader = SnapshotUploader(store: store, sourceDevice: "Mac")
        #expect(await uploader.push(snapshot(usedPercent: 10, readAt: t0), now: t0) == .uploaded)
        let uploads = await store.uploads
        #expect(uploads.count == 1)
        #expect(uploads.first?.sourceDevice == "Mac")
    }

    @Test func sameUsageReadLaterIsSkippedUntilHeartbeat() async {
        let store = FakeCloudStore()
        let uploader = SnapshotUploader(store: store, sourceDevice: "Mac",
                                        policy: .init(minInterval: 60, heartbeat: 900))
        _ = await uploader.push(snapshot(usedPercent: 10, readAt: t0), now: t0)

        let later = t0.addingTimeInterval(120)
        #expect(await uploader.push(snapshot(usedPercent: 10, readAt: later), now: later) == .unchanged)

        let heartbeat = t0.addingTimeInterval(901)
        #expect(await uploader.push(snapshot(usedPercent: 10, readAt: heartbeat), now: heartbeat) == .uploaded)
        #expect(await store.uploads.count == 2)
    }

    @Test func changedUsageIsThrottledThenSentNextCycle() async {
        let store = FakeCloudStore()
        let uploader = SnapshotUploader(store: store, sourceDevice: "Mac",
                                        policy: .init(minInterval: 60, heartbeat: 900))
        _ = await uploader.push(snapshot(usedPercent: 10, readAt: t0), now: t0)

        let soon = t0.addingTimeInterval(30)
        #expect(await uploader.push(snapshot(usedPercent: 20, readAt: soon), now: soon) == .throttled)

        let next = t0.addingTimeInterval(120)
        #expect(await uploader.push(snapshot(usedPercent: 20, readAt: next), now: next) == .uploaded)
        #expect(await store.uploads.count == 2)
    }

    @Test func failedUploadIsRetriedOnNextPush() async {
        let store = FakeCloudStore()
        await store.setFailNext(true)
        let uploader = SnapshotUploader(store: store, sourceDevice: "Mac")
        guard case .failed = await uploader.push(snapshot(usedPercent: 10, readAt: t0), now: t0) else {
            Issue.record("expected a failure"); return
        }
        // Nothing was recorded as sent, so the same content goes up at once.
        let retry = t0.addingTimeInterval(1)
        #expect(await uploader.push(snapshot(usedPercent: 10, readAt: retry), now: retry) == .uploaded)
    }

    @Test func uploadedPayloadRoundTripsToTheSameSnapshot() async throws {
        let store = FakeCloudStore()
        let uploader = SnapshotUploader(store: store, sourceDevice: "Studio")
        let original = snapshot(usedPercent: 42, readAt: t0)
        _ = await uploader.push(original, now: t0)

        let fetched = try await CloudSnapshot.fetchLatest(from: store)
        #expect(fetched?.snapshot == original)
        #expect(fetched?.sourceDevice == "Studio")
        #expect(fetched?.uploadedAt == t0)
    }

    @Test func payloadFromAnotherSchemaVersionIsIgnored() {
        var future = snapshot(usedPercent: 5, readAt: t0)
        future.schemaVersion = WidgetSnapshot.currentSchemaVersion + 1
        let data = WidgetSnapshotStore.encode(future)!
        #expect(CloudSnapshot(record: .init(payload: data, sourceDevice: "Mac", uploadedAt: t0)) == nil)
    }
}
