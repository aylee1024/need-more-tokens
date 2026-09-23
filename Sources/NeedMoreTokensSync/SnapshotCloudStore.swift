import CloudKit
import Foundation

/// One uploaded snapshot as stored in iCloud: the encoded `WidgetSnapshot` plus where and
/// when it came from (the iPhone shows "Updated from <Mac> 2 min ago").
public struct CloudSnapshotRecord: Sendable, Equatable {
    public var payload: Data
    public var sourceDevice: String
    public var uploadedAt: Date

    public init(payload: Data, sourceDevice: String, uploadedAt: Date) {
        self.payload = payload
        self.sourceDevice = sourceDevice
        self.uploadedAt = uploadedAt
    }
}

/// The storage seam, so the upload policy is unit-tested without a live iCloud account.
public protocol SnapshotCloudStoring: Sendable {
    func upload(_ record: CloudSnapshotRecord) async throws
    func downloadLatest() async throws -> CloudSnapshotRecord?
}

/// The user's PRIVATE CloudKit database: exactly one record, `Snapshot/latest`, in a custom
/// zone (a custom zone is what makes a `CKDatabaseSubscription` silent push possible). The
/// payload is an encrypted field, so Apple stores it end-to-end encrypted and it never
/// leaves the user's own iCloud. There is no server of ours anywhere in the path.
///
/// Holds only the container identifier (a String), so it is trivially `Sendable`; the
/// CloudKit objects are created per call, which is cheap.
public struct CloudKitSnapshotStore: SnapshotCloudStoring {
    public static let zoneName = "NMT"
    public static let recordType = "Snapshot"
    public static let recordName = "latest"
    public static let subscriptionID = "nmt-snapshot-changes"

    enum Field {
        static let payload = "payload"
        static let sourceDevice = "sourceDevice"
        static let uploadedAt = "uploadedAt"
    }

    public let containerIdentifier: String
    /// Caps a download's network time. The widget sets it: WidgetKit gives a timeline
    /// reload only a few seconds, and a stalled fetch must fall back to the cached snapshot
    /// rather than get the extension killed. Nil keeps CloudKit's own (long) defaults.
    public let requestTimeout: TimeInterval?

    public init(containerIdentifier: String = CloudSyncConfig.containerIdentifier(),
                requestTimeout: TimeInterval? = nil) {
        self.containerIdentifier = containerIdentifier
        self.requestTimeout = requestTimeout
    }

    private var container: CKContainer { CKContainer(identifier: containerIdentifier) }
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: Self.recordName, zoneID: zoneID) }

    public func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    public func upload(_ snapshot: CloudSnapshotRecord) async throws {
        do {
            try await save(snapshot)
        } catch let error as CKError where Self.isMissingZone(error) {
            try await ensureZone()
            try await save(snapshot)
        }
    }

    public func downloadLatest() async throws -> CloudSnapshotRecord? {
        let record: CKRecord
        let recordID = self.recordID
        do {
            if let requestTimeout {
                let configuration = CKOperation.Configuration()
                configuration.timeoutIntervalForRequest = requestTimeout
                configuration.timeoutIntervalForResource = requestTimeout
                record = try await database.configuredWith(configuration: configuration) { database in
                    try await database.record(for: recordID)
                }
            } else {
                record = try await database.record(for: recordID)
            }
        } catch let error as CKError where error.code == .unknownItem || Self.isMissingZone(error) {
            return nil  // Nothing uploaded yet — not an error.
        }
        guard let payload = record.encryptedValues[Field.payload] as? Data else { return nil }
        return CloudSnapshotRecord(
            payload: payload,
            sourceDevice: record[Field.sourceDevice] as? String ?? "",
            uploadedAt: record[Field.uploadedAt] as? Date ?? record.modificationDate ?? .distantPast
        )
    }

    /// Registers the silent push that tells the iPhone a new snapshot landed. Idempotent:
    /// saving a subscription with the same ID replaces it.
    public func installChangeSubscription() async throws {
        try await ensureZone()
        let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    private func save(_ snapshot: CloudSnapshotRecord) async throws {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record.encryptedValues[Field.payload] = snapshot.payload
        record[Field.sourceDevice] = snapshot.sourceDevice
        record[Field.uploadedAt] = snapshot.uploadedAt
        // `.allKeys` overwrites without a change-tag check: this is a last-writer-wins
        // singleton, so there is nothing to merge and no need to fetch first.
        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [],
                                                            savePolicy: .allKeys)
        if case .failure(let error) = results[recordID] { throw error }
    }

    private func ensureZone() async throws {
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
    }

    private static func isMissingZone(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }
}
