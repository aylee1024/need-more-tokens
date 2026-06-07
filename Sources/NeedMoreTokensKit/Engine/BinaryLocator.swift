import Foundation

/// Finds the `codexbar` binary. Probes, in order: an explicit user override, the
/// two Homebrew prefixes, and the path the Homebrew *cask* installs (the CLI lives
/// inside CodexBar.app and is only symlinked onto `$PATH`, so we check the real
/// location too). A login-shell `command -v` probe is available for unusual PATHs.
public struct BinaryLocator: Sendable {
    public var overridePath: String?

    public init(overridePath: String? = nil) {
        self.overridePath = overridePath
    }

    /// Ordered, non-override probe locations. Verified on macOS Apple Silicon:
    /// the cask links `/opt/homebrew/bin/codexbar` → the in-app `CodexBarCLI`.
    public static let knownPaths: [String] = [
        "/opt/homebrew/bin/codexbar",
        "/usr/local/bin/codexbar",
        "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
    ]

    /// Synchronous probe of override + known paths. Returns nil if none is an
    /// executable file (the caller may then try `locateViaLoginShell`).
    public func locate(fileManager: FileManager = .default) -> URL? {
        var candidates: [String] = []
        if let overridePath, !overridePath.isEmpty { candidates.append(overridePath) }
        candidates.append(contentsOf: Self.knownPaths)
        for path in candidates where Self.isExecutableFile(path, fileManager) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Fallback for custom Homebrew prefixes: resolves `codexbar` through a login
    /// shell, since GUI apps inherit a minimal PATH. Returns nil if not found.
    public func locateViaLoginShell(runner: ProcessClient = ProcessClient(),
                                    fileManager: FileManager = .default) async -> URL? {
        guard let zsh = ["/bin/zsh", "/bin/bash"].first(where: { fileManager.isExecutableFile(atPath: $0) })
        else { return nil }
        guard let data = try? await runner.run(
            executable: URL(fileURLWithPath: zsh),
            arguments: ["-lc", "command -v codexbar"],
            timeout: 10
        ) else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, Self.isExecutableFile(path, fileManager) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func isExecutableFile(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }
}
