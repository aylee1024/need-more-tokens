// swift-tools-version: 6.2
import PackageDescription

// NeedMoreTokensKit holds all the non-UI logic shared by the app and the widget
// extension: provider models, native provider clients, the widget snapshot store,
// and formatting. Keeping it a plain SwiftPM library
// (Foundation-only, no SwiftUI) lets the risky logic — JSON decoding and ledger
// reconciliation — build and test with `swift test`, independent of the macOS 26
// app/widget targets defined in project.yml.
//
// Deployment floor is intentionally lower than the app's (macOS 26): this library
// is pure logic and stays broadly testable on CI. GRDB is added at milestone 4.
//
// iOS is a platform too: the iPhone companion app (a separate, private repo) depends on this
// package for the shared models, the snapshot format, and the Claude client. The CLI-file
// credential loaders compile there but find nothing (see `UserHome`).
//
// NeedMoreTokensSync is the one piece that is NOT Foundation-only: it imports CloudKit to
// carry the Mac's snapshot to the iPhone through the user's private iCloud database. It is a
// separate product so the Kit itself stays pure.
let package = Package(
    name: "NeedMoreTokensKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NeedMoreTokensKit", targets: ["NeedMoreTokensKit"]),
        .library(name: "NeedMoreTokensSync", targets: ["NeedMoreTokensSync"]),
    ],
    targets: [
        .target(
            name: "NeedMoreTokensKit",
            path: "Sources/NeedMoreTokensKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NeedMoreTokensSync",
            dependencies: ["NeedMoreTokensKit"],
            path: "Sources/NeedMoreTokensSync",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NeedMoreTokensKitTests",
            dependencies: ["NeedMoreTokensKit"],
            path: "Tests/NeedMoreTokensKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NeedMoreTokensSyncTests",
            dependencies: ["NeedMoreTokensSync", "NeedMoreTokensKit"],
            path: "Tests/NeedMoreTokensSyncTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
