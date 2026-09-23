import Foundation
#if os(macOS)
import Security
#endif

/// Where the Mac → iPhone snapshot lives in iCloud, and whether this build can reach it.
///
/// The container identifier is read from the host app's Info.plist (`NMTCloudKitContainer`) so
/// a build signed under a different team/bundle prefix points at its own container without a
/// code change; the default matches the shipped bundle prefix.
public enum CloudSyncConfig {
    public static let infoPlistKey = "NMTCloudKitContainer"
    public static let defaultContainerIdentifier = "iCloud.com.aylee1024.needmoretokens"

    public static func containerIdentifier(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? defaultContainerIdentifier
    }

    /// True when this process is signed with an iCloud entitlement naming `container`.
    ///
    /// Load-bearing on macOS: `CKContainer(identifier:)` traps (an uncatchable exception) in a
    /// process without the entitlement, and the default Mac build is deliberately signed
    /// WITHOUT it (see `scripts/build.sh`). Every CloudKit touch in the Mac app is gated on this.
    /// iOS builds always ship the entitlement, so there it is simply true.
    public static func isEntitled(for container: String) -> Bool {
        #if os(macOS)
        return entitledContainerIdentifiers().contains(container)
        #else
        return true
        #endif
    }

    #if os(macOS)
    /// The iCloud containers this process is signed for — empty for the default (ad-hoc or
    /// re-signed) Mac build. The Mac app syncs to the first one, so a build signed under a
    /// different team/prefix follows its own entitlements with no Info.plist key to keep in step.
    public static func entitledContainerIdentifiers() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              ) else { return [] }
        return value as? [String] ?? []
    }
    #endif
}
