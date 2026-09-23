import Foundation

/// The user's home directory. On macOS this is the real `~`, where the provider CLIs keep
/// their credential files. iOS has no shared home (and no `homeDirectoryForCurrentUser`), so
/// the app's own sandbox stands in: the CLI-file loaders still compile there and simply find
/// nothing, which surfaces as the ordinary "not signed in" state.
enum UserHome {
    static var url: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}
