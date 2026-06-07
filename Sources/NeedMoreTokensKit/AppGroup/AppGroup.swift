import Foundation

/// Identifiers shared by the menu-bar app and the widget extension.
///
/// The App Group string MUST be byte-identical in both targets' entitlements and
/// in every container lookup; a single mismatch silently routes the widget to an
/// empty container (it then renders placeholder data forever).
public enum AppIdentifiers {
    public static let appGroup = "group.com.aylee1024.needmoretokens"
    public static let appBundleID = "com.aylee1024.needmoretokens"
    public static let widgetBundleID = "com.aylee1024.needmoretokens.widget"

    public static let widgetSnapshotFilename = "widget-snapshot.json"
    public static let ledgerFilename = "ledger.sqlite"
}

/// Resolves the shared App Group container, with a local Application Support
/// fallback for unsigned/dev builds where the container is unavailable.
///
/// The app (non-sandboxed) and the widget (sandboxed) both reach the same files
/// through this single entry point. When the group container is present, both land
/// in it. When it is not (e.g. an ad-hoc-signed local build), the app still works
/// via the fallback directory and the widget shows placeholder data — surfaced to
/// the user rather than failing silently.
public enum AppGroupContainer {
    /// Directory used for shared files. Never throws: always returns a usable URL.
    /// Prefers the App Group container, but only if it actually exists or can be
    /// created — `containerURL` returns a path even for an app without the
    /// entitlement, and writing there silently fails. Falls back to Application
    /// Support otherwise so the app always has a working store.
    public static func directory(fileManager: FileManager = .default) -> URL {
        if let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup
        ), ensureDirectoryExists(container, fileManager: fileManager) {
            return container
        }
        return localFallbackDirectory(fileManager: fileManager)
    }

    private static func ensureDirectoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        return (try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    }

    /// `true` when the real App Group container is available (not the fallback).
    /// The app surfaces this in diagnostics so a missing-entitlement misconfig is
    /// visible instead of mysterious stale widgets.
    public static func isUsingSharedContainer(fileManager: FileManager = .default) -> Bool {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup
        ) else { return false }
        return ensureDirectoryExists(container, fileManager: fileManager)
    }

    public static func fileURL(_ name: String, fileManager: FileManager = .default) -> URL {
        directory(fileManager: fileManager).appendingPathComponent(name, isDirectory: false)
    }

    public static var snapshotURL: URL { fileURL(AppIdentifiers.widgetSnapshotFilename) }
    public static var ledgerURL: URL { fileURL(AppIdentifiers.ledgerFilename) }

    private static func localFallbackDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("NeedMoreTokens", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
