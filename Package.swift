// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clippy",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Clippy",
            path: "Sources/Clippy",
            swiftSettings: [
                // Use the Swift 5 language mode to keep AppKit/SwiftUI bridging
                // ergonomic; the app is single-process and @MainActor-centric.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
