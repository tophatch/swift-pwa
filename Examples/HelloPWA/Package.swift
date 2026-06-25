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
                // Opt-in zip extractor for the content-packs demo. Pulls in
                // ZIPFoundation only because this app imports it — apps that
                // don't need pack import link neither it nor `fs.extractZip`.
                // Gated off Android: ZIPFoundation can't build against Bionic
                // libc, so on Android the demo uses `AndroidArchiveExtractor`
                // (from the SwiftPWA umbrella) instead of `ZIPExtractor`.
                .product(
                    name: "SwiftPWAArchive",
                    package: "swift-pwa",
                    condition: .when(platforms: [.macOS, .iOS, .linux, .windows])
                ),
            ],
            resources: [.copy("web")],
            linkerSettings: [
                // On Android, the Swift binary is loaded by the
                // generated Kotlin Activity via `System.loadLibrary`,
                // so it has to be a shared object (.so) rather than an
                // ELF executable. SwiftPM doesn't expose a "build this
                // executable target as a shared library" knob, so we
                // inject the linker flags directly. `-no-pie` cancels
                // the toolchain's default `-pie` (which is mutually
                // exclusive with `-shared` under `lld`); `-shared`
                // produces the actual .so. The lone Android-only
                // invariant in this Package.swift.
                .unsafeFlags(
                    ["-Xlinker", "-no-pie", "-Xlinker", "-shared"],
                    .when(platforms: [.android])
                ),
            ]
        ),
    ]
)
