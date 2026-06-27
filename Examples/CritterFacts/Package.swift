// swift-tools-version:6.0
import Foundation
import PackageDescription

// Standalone example showcasing the on-device **llama.cpp** backend. Uses a
// path-based dependency so it tracks the repo it lives in; real consumers would
// use a versioned URL.
//
// `SwiftPWALlama` is an *env-gated* product of swift-pwa — it only exists in the
// package graph when `SWIFT_PWA_LLAMA` is set, which `swift-pwa build` does from
// `ai.local_llama: true` in pwa.json. So we add the dependency conditionally
// (referencing a product that isn't there fails resolution) and the app
// `#if canImport`s it. Built without the flag, you get the window-only shell
// with a "build with ai.local_llama" note instead of a crash.
let llamaEnabled = ProcessInfo.processInfo.environment["SWIFT_PWA_LLAMA"] != nil

var appDependencies: [Target.Dependency] = [
    .product(name: "SwiftPWA", package: "swift-pwa"),
    // ModelSpec (the downloadable-model descriptor) lives here. Not env-gated.
    .product(name: "SwiftPWAModelStore", package: "swift-pwa"),
]
if llamaEnabled {
    appDependencies.append(.product(name: "SwiftPWALlama", package: "swift-pwa"))
}

let package = Package(
    name: "CritterFacts",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        .package(name: "swift-pwa", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "CritterFacts",
            dependencies: appDependencies,
            resources: [.copy("web")],
            linkerSettings: [
                // On Android the binary is loaded by the generated Kotlin
                // Activity via `System.loadLibrary`, so it must be a shared
                // object. SwiftPM has no "executable as .so" knob, so inject
                // the flags: `-no-pie` cancels the toolchain default (mutually
                // exclusive with `-shared` under lld); `-shared` emits the .so.
                .unsafeFlags(
                    ["-Xlinker", "-no-pie", "-Xlinker", "-shared"],
                    .when(platforms: [.android])
                ),
            ]
        ),
    ]
)
