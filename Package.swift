// swift-tools-version:6.0
import Foundation
import PackageDescription

// swift-tools-version:6.0 already enables strict concurrency by default;
// only opt in to features that aren't yet baseline. The Linux toolchain
// treats `enableUpcomingFeature("StrictConcurrency")` under Swift 6 as
// an error rather than a warning, which broke `swift build` on Ubuntu.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

/// Linux backend selection. The default is GTK3 + WebKitGTK 4.1, which
/// builds against any Ubuntu 22.04+ / Fedora 36+ box. Set
/// `SWIFT_PWA_GTK4=1` in the environment to compile against GTK4 +
/// WebKitGTK 6.0 instead — needed on distros that have moved past the
/// 4.1 ABI and as the long-term direction. The two backends export the
/// same Swift module name (`SwiftPWAGTK`) so the umbrella and downstream
/// users don't need to know which is in use.
let useGtk4 = ProcessInfo.processInfo.environment["SWIFT_PWA_GTK4"] != nil

let gtkSystemLibraryTarget: Target = useGtk4
    ? .systemLibrary(
        name: "CGtk4Shim",
        path: "Sources/CGtk4Shim",
        pkgConfig: "gtk4",
        providers: [
            .apt(["libgtk-4-dev"]),
            .brew(["gtk4"])
        ]
    )
    : .systemLibrary(
        name: "CGtk3Shim",
        path: "Sources/CGtk3Shim",
        pkgConfig: "gtk+-3.0",
        providers: [
            .apt(["libgtk-3-dev"]),
            .brew(["gtk+3"])
        ]
    )

let webkitSystemLibraryTarget: Target = useGtk4
    ? .systemLibrary(
        name: "CWebKitGTK6Shim",
        path: "Sources/CWebKitGTK6Shim",
        pkgConfig: "webkitgtk-6.0",
        providers: [
            .apt(["libwebkitgtk-6.0-dev"])
        ]
    )
    : .systemLibrary(
        name: "CWebKitGTK4Shim",
        path: "Sources/CWebKitGTK4Shim",
        pkgConfig: "webkit2gtk-4.1",
        providers: [
            .apt(["libwebkit2gtk-4.1-dev"])
        ]
    )

let gtkBackendTarget: Target = useGtk4
    ? .target(
        name: "SwiftPWAGTK",
        dependencies: [
            "SwiftPWACore",
            .target(name: "CGtk4Shim", condition: .when(platforms: [.linux])),
            .target(name: "CWebKitGTK6Shim", condition: .when(platforms: [.linux]))
        ],
        path: "Sources/SwiftPWAGTK4",
        swiftSettings: swiftSettings
    )
    : .target(
        name: "SwiftPWAGTK",
        dependencies: [
            "SwiftPWACore",
            .target(name: "CGtk3Shim", condition: .when(platforms: [.linux])),
            .target(name: "CWebKitGTK4Shim", condition: .when(platforms: [.linux]))
        ],
        path: "Sources/SwiftPWAGTK",
        swiftSettings: swiftSettings
    )

let package = Package(
    name: "swift-pwa",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "SwiftPWA", targets: ["SwiftPWA"]),
        .library(name: "SwiftPWACore", targets: ["SwiftPWACore"]),
        .library(name: "SwiftPWATestSupport", targets: ["_SwiftPWATestSupport"]),
        .executable(name: "swift-pwa", targets: ["swift-pwa-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        // MARK: - Platform-agnostic core

        .target(
            name: "SwiftPWACore",
            resources: [
                .copy("Resources/bridge.js")
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

        // MARK: - Linux backend (GTK3 or GTK4 — selected via SWIFT_PWA_GTK4)

        gtkSystemLibraryTarget,
        webkitSystemLibraryTarget,
        gtkBackendTarget,

        // MARK: - Umbrella

        .target(
            name: "SwiftPWA",
            dependencies: [
                "SwiftPWACore",
                .target(name: "SwiftPWAWebKit", condition: .when(platforms: [.macOS, .iOS])),
                .target(name: "SwiftPWAGTK", condition: .when(platforms: [.linux]))
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - CLI

        .executableTarget(
            name: "swift-pwa-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
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
                "_SwiftPWATestSupport"
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWAGTKTests",
            dependencies: [
                .target(name: "SwiftPWAGTK", condition: .when(platforms: [.linux])),
                "_SwiftPWATestSupport"
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWACLITests",
            dependencies: ["swift-pwa-cli"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: swiftSettings
        )
    ]
)
