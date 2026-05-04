// swift-tools-version:6.0
import PackageDescription

// Standalone example. Uses a path-based dependency so it tracks the
// repo it lives in. Real consumers would use a versioned URL.
let package = Package(
    name: "HelloPWA",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        .package(name: "swift-pwa", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "HelloPWA",
            dependencies: [
                .product(name: "SwiftPWA", package: "swift-pwa"),
            ],
            resources: [.copy("web")]
        ),
    ]
)
