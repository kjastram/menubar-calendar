// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Almanac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Almanac", targets: ["Almanac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/openid/AppAuth-iOS.git", from: "2.0.0"),
    ],
    targets: [
        // Shared models and protocols. No dependencies, so every other target can build on its own.
        .target(name: "AlmanacKit"),
        // Google sign-in (AppAuth loopback + PKCE) and Keychain storage.
        .target(name: "AlmanacAuth", dependencies: [
            "AlmanacKit",
            .product(name: "AppAuth", package: "AppAuth-iOS"),
        ]),
        // Google Calendar API client, SQLite cache, sync.
        .target(name: "AlmanacData", dependencies: [
            "AlmanacKit",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        // Main window views and state. Talks to data only through AlmanacKit protocols.
        .target(name: "AlmanacUI", dependencies: ["AlmanacKit"]),
        // App entry point: wiring, menu bar popover, settings window.
        .executableTarget(name: "Almanac", dependencies: [
            "AlmanacKit", "AlmanacAuth", "AlmanacData", "AlmanacUI",
        ]),
        .testTarget(name: "AlmanacDataTests", dependencies: [
            "AlmanacData",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "AlmanacAuthTests", dependencies: ["AlmanacAuth"]),
        .testTarget(name: "AlmanacUITests", dependencies: ["AlmanacUI", "AlmanacKit"]),
    ]
)
