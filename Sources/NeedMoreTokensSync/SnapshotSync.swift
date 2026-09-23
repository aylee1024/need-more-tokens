import Foundation
import NeedMoreTokensKit

/// Decides WHEN the Mac uploads its snapshot for the iPhone, and does it.
///
/// The Mac refreshes every ~2 minutes, and nearly every refresh differs only in timestamps.
/// Uploading each one would spend iCloud requests and — worse — wake the iPhone with a
/// silent push each time, which iOS throttles and then starts dropping. So:
/// - a snapshot whose CONTENT (timestamps ignored) is unchanged is skipped, except for a
///   periodic heartbeat so the phone can tell "Mac is alive, nothing moved" from "Mac is off";
/// - changed content uploads at most once per `minInterval`; a throttled change goes up on
///   the next refresh after the interval, so nothing is lost for longer than one cycle.
public actor SnapshotUploader {
    public struct Policy: Sendable {
        public var minInterval: TimeInterval
        public var heartbeat: TimeInterval
        public init(minInterval: TimeInterval = 60, heartbeat: TimeInterval = 15 * 60) {
            self.minInterval = minInterval
            self.heartbeat = heartbeat
        }
    }

    public enum Outcome: Sendable, Equatable {
        case uploaded
        case unchanged
        case throttled
        case failed(String)
    }

    private let store: any SnapshotCloudStoring
    private let policy: Policy
    private let sourceDevice: String
    private var lastFingerprint: Data?
    private var lastUpload: Date?
    private var inFlight = false

    public init(store: any SnapshotCloudStoring, sourceDevice: String, policy: Policy = Policy()) {
        self.store = store
        self.sourceDevice = sourceDevice
        self.policy = policy
    }

    public func push(_ snapshot: WidgetSnapshot, now: Date = Date()) async -> Outcome {
        guard !inFlight else { return .throttled }
        guard let payload = WidgetSnapshotStore.encode(snapshot) else { return .failed("encode") }
        let fingerprint = Self.fingerprint(of: snapshot)
        let sinceLast = lastUpload.map { now.timeIntervalSince($0) } ?? .infinity

        if fingerprint == lastFingerprint {
            guard sinceLast >= policy.heartbeat else { return .unchanged }
        } else if sinceLast < policy.minInterval {
            return .throttled
        }

        inFlight = true
        defer { inFlight = false }
        do {
            try await store.upload(CloudSnapshotRecord(payload: payload, sourceDevice: sourceDevice,
                                                       uploadedAt: now))
            lastFingerprint = fingerprint
            lastUpload = now
            return .uploaded
        } catch {
            return .failed(String(describing: type(of: error)))
        }
    }

    /// The snapshot's encoding with every "when was this read" timestamp blanked, so two
    /// readings of the same usage compare equal. Reset times (`resetsAt`) are content and stay.
    static func fingerprint(of snapshot: WidgetSnapshot) -> Data? {
        var stripped = snapshot
        stripped.generatedAt = Date(timeIntervalSince1970: 0)
        for index in stripped.entries.indices {
            stripped.entries[index].updatedAt = nil
        }
        return WidgetSnapshotStore.encode(stripped)
    }
}

/// A downloaded snapshot, decoded, with its provenance.
public struct CloudSnapshot: Sendable, Equatable {
    public var snapshot: WidgetSnapshot
    public var sourceDevice: String
    public var uploadedAt: Date

    public init(snapshot: WidgetSnapshot, sourceDevice: String, uploadedAt: Date) {
        self.snapshot = snapshot
        self.sourceDevice = sourceDevice
        self.uploadedAt = uploadedAt
    }

    /// Decodes a stored record; nil if the payload is corrupt or from another schema version
    /// (an older phone reading a newer Mac's payload shows "update the app", not garbage).
    public init?(record: CloudSnapshotRecord) {
        guard let snapshot = WidgetSnapshotStore.decode(record.payload) else { return nil }
        self.init(snapshot: snapshot, sourceDevice: record.sourceDevice, uploadedAt: record.uploadedAt)
    }

    public static func fetchLatest(from store: any SnapshotCloudStoring) async throws -> CloudSnapshot? {
        try await store.downloadLatest().flatMap(CloudSnapshot.init(record:))
    }
}
