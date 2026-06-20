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
let package = Package(
    name: "NeedMoreTokensKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NeedMoreTokensKit", targets: ["NeedMoreTokensKit"]),
    ],
    targets: [
        .target(
            name: "NeedMoreTokensKit",
            path: "Sources/NeedMoreTokensKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NeedMoreTokensKitTests",
            dependencies: ["NeedMoreTokensKit"],
            path: "Tests/NeedMoreTokensKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
