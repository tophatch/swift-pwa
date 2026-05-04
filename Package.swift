// swift-tools-version:6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "swift-pwa",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "SwiftPWA", targets: ["SwiftPWA"]),
        .library(name: "SwiftPWACore", targets: ["SwiftPWACore"]),
        .library(name: "SwiftPWATestSupport", targets: ["_SwiftPWATestSupport"]),
        .executable(name: "swift-pwa", targets: ["swift-pwa-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // MARK: - Platform-agnostic core
        .target(
            name: "SwiftPWACore",
            resources: [
                .copy("Resources/bridge.js"),
            ],
            swiftSettings: swiftSettings
        ),

        .target(
            name: "_SwiftPWATestSupport",
            dependencies: ["SwiftPWACore"],
            swiftSettings: swiftSettings
        ),

        // MARK: - Apple backend (macOS + iOS)
        .target(
            name: "SwiftPWAWebKit",
            dependencies: ["SwiftPWACore"],
            swiftSettings: swiftSettings
        ),

        // MARK: - Linux backend
        .systemLibrary(
            name: "CGtk3Shim",
            path: "Sources/CGtk3Shim",
            pkgConfig: "gtk+-3.0",
            providers: [
                .apt(["libgtk-3-dev"]),
                .brew(["gtk+3"]),
            ]
        ),
        .systemLibrary(
            name: "CWebKitGTK4Shim",
            path: "Sources/CWebKitGTK4Shim",
            pkgConfig: "webkit2gtk-4.1",
            providers: [
                .apt(["libwebkit2gtk-4.1-dev"]),
            ]
        ),
        .target(
            name: "SwiftPWAGTK",
            dependencies: [
                "SwiftPWACore",
                .target(name: "CGtk3Shim", condition: .when(platforms: [.linux])),
                .target(name: "CWebKitGTK4Shim", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Umbrella
        .target(
            name: "SwiftPWA",
            dependencies: [
                "SwiftPWACore",
                .target(name: "SwiftPWAWebKit", condition: .when(platforms: [.macOS, .iOS])),
                .target(name: "SwiftPWAGTK", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - CLI
        .executableTarget(
            name: "swift-pwa-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Tests
        .testTarget(
            name: "SwiftPWACoreTests",
            dependencies: ["SwiftPWACore", "_SwiftPWATestSupport"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWAWebKitTests",
            dependencies: [
                .target(name: "SwiftPWAWebKit", condition: .when(platforms: [.macOS, .iOS])),
                "_SwiftPWATestSupport",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWAGTKTests",
            dependencies: [
                .target(name: "SwiftPWAGTK", condition: .when(platforms: [.linux])),
                "_SwiftPWATestSupport",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWACLITests",
            dependencies: ["swift-pwa-cli"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
