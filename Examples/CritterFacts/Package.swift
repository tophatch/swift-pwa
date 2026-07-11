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
// `SwiftPWAPhiSilica` is the analogous env-gated product for the Windows
// platform built-in (Phi Silica). `swift-pwa build` sets SWIFT_PWA_PHI_SILICA
// from `ai.phi_silica: true`; add the dependency only then, same as llama.
let phiSilicaEnabled = ProcessInfo.processInfo.environment["SWIFT_PWA_PHI_SILICA"] != nil
// `SwiftPWASegmentation` (MobileSAMBackend, `ai.vision.*`) is the analogous
// env-gated product for on-device segmentation — `swift-pwa build` sets
// SWIFT_PWA_ONNXRUNTIME from `ai.local_onnx_runtime: true`, same as llama/Phi
// Silica above (Apple + Android; no Linux/Windows backend yet).
let onnxRuntimeEnabled = ProcessInfo.processInfo.environment["SWIFT_PWA_ONNXRUNTIME"] != nil

var appDependencies: [Target.Dependency] = [
    .product(name: "SwiftPWA", package: "swift-pwa"),
    // ModelSpec (the downloadable-model descriptor) lives here. Not env-gated.
    .product(name: "SwiftPWAModelStore", package: "swift-pwa"),
]
if llamaEnabled {
    appDependencies.append(.product(name: "SwiftPWALlama", package: "swift-pwa"))
}
if phiSilicaEnabled {
    appDependencies.append(.product(name: "SwiftPWAPhiSilica", package: "swift-pwa"))
}
if onnxRuntimeEnabled {
    appDependencies.append(.product(name: "SwiftPWASegmentation", package: "swift-pwa"))
    // LaMaBackend (`ai.generateImage` inpainting) — same ONNX Runtime gate,
    // composed with the text backend behind one `ai.*` surface (tap-to-erase).
    appDependencies.append(.product(name: "SwiftPWAImageEdit", package: "swift-pwa"))
    // StableDiffusionBackend (`ai.generateImage` text→image) — same gate,
    // composed alongside LaMa behind the one `ai.*` surface (prompt-to-image).
    appDependencies.append(.product(name: "SwiftPWAStableDiffusion", package: "swift-pwa"))
}

// Opt-in build flag for the headless on-device LaMa inpaint smoke (Android
// verification of the image-edit codec path — see CritterFacts.swift). Off in
// normal builds; set SWIFT_PWA_CF_LAMA_SMOKE=1 to compile it in.
let lamaSmoke = ProcessInfo.processInfo.environment["SWIFT_PWA_CF_LAMA_SMOKE"] != nil
let appSwiftSettings: [SwiftSetting] = lamaSmoke ? [.define("CRITTERFACTS_LAMA_SMOKE")] : []

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
            swiftSettings: appSwiftSettings,
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
                // Note: linking the ONNX Runtime xcframework needs libc++ on
                // Apple, but `SwiftPWASegmentation` now declares that itself
                // (its linkerSettings propagate here), so this app doesn't.
            ]
        ),
    ]
)
