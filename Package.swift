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

// Echo the selection during manifest evaluation so it's obvious which
// backend you're building. SwiftPM caches the resolved manifest by
// hashing Package.swift, so changing this env var doesn't invalidate
// the cache on its own — you need `swift package clean` (or
// `rm -rf .build`) when toggling between GTK3 and GTK4.
FileHandle.standardError.write(
    Data("swift-pwa: Linux backend selection = \(useGtk4 ? "GTK4 + WebKitGTK 6.0" : "GTK3 + WebKitGTK 4.1")\n".utf8)
)

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

/// `libayatana-appindicator3` is GTK3-only (a single process can't link
/// both GTK3 and GTK4), so the AppIndicator shim is part of the GTK3
/// backend dep set only. The GTK4 backend's `SystemTray` stays a no-op
/// stub until `libayatana-appindicator-gtk4` becomes broadly packaged.
let appIndicatorSystemLibraryTarget: Target? = useGtk4
    ? nil
    : .systemLibrary(
        name: "CAyatanaAppIndicator3Shim",
        path: "Sources/CAyatanaAppIndicator3Shim",
        pkgConfig: "ayatana-appindicator3-0.1",
        providers: [
            .apt(["libayatana-appindicator3-dev"])
        ]
    )

/// swift-crypto's `Crypto` module is API-compatible with CryptoKit and is
/// what `LinuxAppImageUpdater` uses for Ed25519 verification (CryptoKit
/// itself is Apple-only). On Apple it shadows CryptoKit; on Linux it
/// links against BoringSSL. Linux-conditional because the GTK target's
/// .swift sources are all `#if os(Linux)`-guarded — pulling Crypto in on
/// macOS hosts where the GTK target compiles to an empty object would
/// just bloat the link.
let gtkBackendTarget: Target = useGtk4
    ? .target(
        name: "SwiftPWAGTK",
        dependencies: [
            "SwiftPWACore",
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
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
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            .target(name: "CGtk3Shim", condition: .when(platforms: [.linux])),
            .target(name: "CWebKitGTK4Shim", condition: .when(platforms: [.linux])),
            .target(name: "CAyatanaAppIndicator3Shim", condition: .when(platforms: [.linux]))
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
        // Optional ZIP-extraction engine for `fs.extractZip`. Apps that
        // import content packs add this product and inject
        // `ZIPExtractor()` into `FsPlugin`; everyone else links neither it
        // nor ZIPFoundation.
        .library(name: "SwiftPWAArchive", targets: ["SwiftPWAArchive"]),
        // Optional on-device AI backend (Apple Foundation Models) for the
        // `ai.*` plugin. Apps that want on-device inference add this product
        // and inject `FoundationModelsBackend()` into `AIPlugin`; everyone
        // else links neither it nor the FoundationModels framework.
        .library(name: "SwiftPWAFoundationModels", targets: ["SwiftPWAFoundationModels"]),
        // Reusable downloadable-model store powering `ai.ensureModel` —
        // resumable, checksum-pinned model downloads cached on disk. Used by
        // backends that ship a downloadable model (llama.cpp / the Gemma
        // tier); apps that only use a platform built-in (Foundation Models)
        // never link it.
        .library(name: "SwiftPWAModelStore", targets: ["SwiftPWAModelStore"]),
        .library(name: "SwiftPWATestSupport", targets: ["_SwiftPWATestSupport"]),
        .executable(name: "swift-pwa", targets: ["swift-pwa-cli"]),
        // CI-internal: the Windows test runner. See the matching
        // executableTarget below for why a regular swift-testing target
        // doesn't work on Windows. Surfaced as a product so it shows up
        // in `swift package describe` / `products:` grep — a Windows
        // reviewer hit the discoverability gap when only the target
        // existed.
        .executable(name: "SwiftPWAWindowsTestRunner", targets: ["SwiftPWAWindowsTestRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // swift-crypto gives the `swift-pwa updater` CLI subcommands an
        // Ed25519 implementation that works on Linux and Windows hosts
        // too — CryptoKit is Apple-only, but `import Crypto` from
        // swift-crypto presents an API-compatible surface across
        // platforms (and on Apple it just shadows CryptoKit). The CLI
        // is the only consumer; the runtime side stays on CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0" ..< "5.0.0"),
        // ZIPFoundation backs the optional `SwiftPWAArchive` target (the
        // `fs.extractZip` engine). It's isolated in its own target so apps
        // that don't import content packs never link it — `SwiftPWACore`
        // stays free of third-party runtime dependencies.
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.0")
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

        // MARK: - Optional ZIP-extraction engine (fs.extractZip)

        // Isolated so the ZIPFoundation dependency is linked only by apps
        // that opt into content-pack import. `SwiftPWACore` defines the
        // `ArchiveExtractor` protocol; this target provides the concrete
        // `ZIPExtractor`. The umbrella deliberately does NOT depend on it.
        .target(
            name: "SwiftPWAArchive",
            dependencies: [
                "SwiftPWACore",
                // ZIPFoundation doesn't build on Windows (its CZLib shim
                // uses `#import <zlib.h>`, which clang-cl rejects, and
                // Windows ships no system zlib). It *also* can't build for
                // Android: it assumes glibc/Darwin POSIX (`lstat`, `errno`,
                // `S_IF*`, `mode_t` as Int32), none of which resolve against
                // Bionic libc. So gate it to macOS / iOS / Linux. Windows uses
                // a `tar.exe`-backed `ZIPExtractor`; Android uses
                // `AndroidArchiveExtractor` (Kotlin `java.util.zip` over JNI).
                .product(
                    name: "ZIPFoundation",
                    package: "ZIPFoundation",
                    condition: .when(platforms: [.macOS, .iOS, .linux])
                )
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Optional on-device AI backend (Apple Foundation Models)

        // Isolated so the FoundationModels framework is linked only by apps
        // that opt into on-device inference. `SwiftPWACore` defines the
        // `AIBackend` protocol; this target provides `FoundationModelsBackend`.
        // macOS/iOS only (the framework doesn't exist elsewhere); the code is
        // further guarded by `#if canImport(FoundationModels)` +
        // `@available(macOS 26, iOS 26, *)` so it still builds on an older SDK
        // (degrading to an `available:false` stub). The umbrella does NOT
        // depend on it.
        .target(
            name: "SwiftPWAFoundationModels",
            dependencies: ["SwiftPWACore"],
            swiftSettings: swiftSettings
        ),

        // MARK: - Downloadable-model store (ai.ensureModel)

        // Resumable, checksum-pinned model downloads for backends that ship
        // a downloadable model (llama.cpp / Gemma tier). SHA-256 uses
        // CryptoKit on Apple (no dependency) and swift-crypto's `Crypto`
        // elsewhere — the same split the updater uses.
        .target(
            name: "SwiftPWAModelStore",
            dependencies: [
                "SwiftPWACore",
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .windows, .android])
                )
            ],
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
        gtkBackendTarget
    ] + (appIndicatorSystemLibraryTarget.map { [$0] } ?? []) + [
        // MARK: - Android backend (android.webkit.WebView via a JNI C shim)

        //
        // Android's UI thread is owned by the JVM. Our Swift code
        // compiles to a shared object loaded by a Kotlin `Activity`
        // via `System.loadLibrary`. The C shim is the JNI boundary:
        //   - inbound: Java calls JNI funcs that hand JSON frames to
        //     Swift (`swiftpwa_android_ingest`).
        //   - outbound: Swift calls C wrappers that re-enter the JVM
        //     to drive `WebView.evaluateJavascript`, `WebView.loadUrl`,
        //     and `Handler.post(Looper.getMainLooper())` for the
        //     `MainThread.run` hook.
        //
        // The shim is a regular C target. NDK headers come from the
        // Android Swift SDK install (Swift 6.1+); the build is
        // gated to Android via `.when(platforms: [.android])`. On
        // host platforms (macOS, Linux, Windows) the .swift sources
        // are `#if os(Android)`-guarded so they compile to empty
        // objects.

        .target(
            name: "CSwiftPWAAndroidJNI",
            path: "Sources/CSwiftPWAAndroidJNI",
            publicHeadersPath: "include",
            cSettings: [
                .define("_GNU_SOURCE", .when(platforms: [.android]))
            ],
            linkerSettings: [
                // `liblog` carries `__android_log_print`, used by the
                // shim's diagnostics. `libandroid` exposes `ANativeWindow`
                // and friends (we don't use them yet in v0.5 but they're
                // routinely needed by webview-adjacent code; pulling
                // the link dep in now keeps follow-up work cheap).
                .linkedLibrary("log", .when(platforms: [.android])),
                .linkedLibrary("android", .when(platforms: [.android]))
            ]
        ),

        .target(
            name: "SwiftPWAAndroid",
            dependencies: [
                "SwiftPWACore",
                // swift-crypto's `Crypto` module — same conditional
                // wiring as the GTK / Windows backends, available
                // for an Android updater backend in a future v0.5.x
                // (not implemented yet).
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.android])),
                .target(name: "CSwiftPWAAndroidJNI", condition: .when(platforms: [.android]))
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Windows backend (WebView2 via a C++ COM shim)

        //
        // The shim is a regular C/C++ target (not a systemLibrary)
        // because it actually compiles source — the WebView2 SDK is
        // header-only on the build side but its COM interfaces need
        // real C++ to wrangle from. The Windows SDK headers
        // (`<windows.h>`, `<WebView2.h>`) come from the standard
        // include path on a Swift-on-Windows install. The static
        // loader (`WebView2LoaderStatic.lib`) is shipped in the
        // `Microsoft.Web.WebView2` NuGet package; see
        // `docs/windows-setup.md` for how to put it on the link path.

        .target(
            name: "CWebView2Shim",
            path: "Sources/CWebView2Shim",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("UNICODE", .when(platforms: [.windows])),
                .define("_UNICODE", .when(platforms: [.windows])),
                .define("WIN32_LEAN_AND_MEAN", .when(platforms: [.windows]))
            ],
            linkerSettings: [
                .linkedLibrary("WebView2LoaderStatic", .when(platforms: [.windows])),
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                .linkedLibrary("oleaut32", .when(platforms: [.windows])),
                .linkedLibrary("shlwapi", .when(platforms: [.windows])),
                .linkedLibrary("user32", .when(platforms: [.windows])),
                .linkedLibrary("shell32", .when(platforms: [.windows])),
                .linkedLibrary("RuntimeObject", .when(platforms: [.windows])),
                // TaskDialogIndirect (themed message + confirm boxes) lives
                // in `comctl32`. Required by the dialog shim.
                .linkedLibrary("comctl32", .when(platforms: [.windows])),
                // C++/WinRT (`<winrt/...>`) calls dispatch through
                // `WindowsApp.lib`. cl.exe picks it up via a
                // `#pragma comment(lib, ...)` in `<winrt/base.h>`,
                // but lld-link in clang-mode under SwiftPM doesn't
                // always honour the pragma — link it explicitly so
                // toast notifications resolve at link time.
                .linkedLibrary("WindowsApp", .when(platforms: [.windows]))
            ]
        ),

        .target(
            name: "SwiftPWAWindows",
            dependencies: [
                "SwiftPWACore",
                // swift-crypto's `Crypto` module is what `WindowsUpdater`
                // uses for Ed25519 verification. Same rationale as the
                // GTK targets — Linux/Windows-conditional so the empty
                // object on macOS hosts doesn't pull BoringSSL in.
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.windows])),
                .target(name: "CWebView2Shim", condition: .when(platforms: [.windows]))
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
                .target(name: "SwiftPWAWindows", condition: .when(platforms: [.windows])),
                .target(name: "SwiftPWAAndroid", condition: .when(platforms: [.android]))
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - CLI

        //
        // Split into a library (`SwiftPWACLISupport`, holds the
        // bundlers, command structs, manifest decoder) and a thin
        // executable target that owns just the `@main` entry. The
        // split exists because Swift on Windows otherwise emits a
        // `main` symbol from the executable target's source list
        // that collides with the test runner's own `main` when the
        // CLI test target depends on the executable for `@testable
        // import`. With the split, tests depend on the library and
        // never see the entry point.

        .target(
            name: "SwiftPWACLISupport",
            dependencies: [
                "SwiftPWACore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            // No `resources:` on purpose. The vendored Gradle wrapper (pinned
            // version, in `Vendor/gradle-wrapper/`) is base64-embedded into
            // `Generated/GradleWrapperData.swift` instead of shipped as a
            // SwiftPM resource bundle — so a prebuilt single-file `swift-pwa`
            // binary stages `./gradlew` too, and `Bundle.module` (which
            // *traps* when the bundle isn't co-located) is never synthesized
            // for this target. Regenerate via Scripts/regenerate-gradle-wrapper.sh.
            swiftSettings: swiftSettings
        ),

        .executableTarget(
            name: "swift-pwa-cli",
            dependencies: [
                "SwiftPWACLISupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: swiftSettings
        ),

        // Windows-only test runner. Replaces what would normally be a
        // `swift-testing` test target — SwiftPM's discovery build plugin
        // emits 0-byte stubs for every suite on Windows (Swift 6.1.2 +
        // 6.3.1, both x64 and arm64), so the test bundle finds zero tests
        // and `swift test` exits 1 with no output. See
        // docs/windows-setup.md "Known limitations".
        .executableTarget(
            name: "SwiftPWAWindowsTestRunner",
            dependencies: [
                .target(name: "SwiftPWAWindows", condition: .when(platforms: [.windows])),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.windows]))
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
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                "_SwiftPWATestSupport"
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWAAndroidTests",
            dependencies: [
                .target(name: "SwiftPWAAndroid", condition: .when(platforms: [.android])),
                "_SwiftPWATestSupport"
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWAFoundationModelsTests",
            dependencies: [
                "SwiftPWAFoundationModels",
                "SwiftPWACore"
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWAModelStoreTests",
            dependencies: [
                "SwiftPWAModelStore",
                "SwiftPWACore"
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWAArchiveTests",
            dependencies: [
                "SwiftPWAArchive",
                "SwiftPWACore",
                "_SwiftPWATestSupport",
                // Same Windows gate as the target — the round-trip tests
                // drive ZIPFoundation directly, which doesn't build on
                // Windows. The test file is `#if canImport(ZIPFoundation)`.
                .product(
                    name: "ZIPFoundation",
                    package: "ZIPFoundation",
                    condition: .when(platforms: [.macOS, .iOS, .linux, .android])
                )
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiftPWACLITests",
            dependencies: [
                "SwiftPWACLISupport",
                "SwiftPWACore",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: swiftSettings
        )
    ],
    // C++20 — required by C++/WinRT under the Swift-for-Windows
    // toolchain. cppwinrt's coroutine support detects the compiler
    // mode at preprocess time: under C++17 it tries to include
    // `<experimental/coroutine>`, which the MSVC STL rejects when
    // the front-end is clang (Swift-for-Windows builds C++ via
    // clang-cl). Under C++20 cppwinrt uses the standard `<coroutine>`
    // header instead, which compiles cleanly. WIL and WebView2.h are
    // both happy under C++20.
    cxxLanguageStandard: .cxx20
)

// MARK: - Optional llama.cpp backend (env-gated, prebuilt xcframework)

// The portable on-device AI backend (`SwiftPWALlama` / `LlamaBackend`) links a
// prebuilt llama.cpp xcframework via `.binaryTarget`. A binaryTarget is
// resolved *eagerly* for every consumer of a package, so we must NOT declare
// it unconditionally — that would force a ~30MB Apple-only download (and an
// xcframework resolution Linux/Windows can't satisfy) onto every adopter.
//
// Instead it's gated behind `SWIFT_PWA_LLAMA=1`, the same `ProcessInfo`
// manifest-toggle pattern as `useGtk4` above. Adopters never set it by hand:
// `swift-pwa build` reads `ai.local_llama: true` from `pwa.json` and sets it in
// the environment it passes to `swift build` / `xcodebuild`. When unset, this
// whole block is skipped — the binaryTarget isn't in the graph, so there's
// nothing to download and nothing for non-Apple hosts to choke on.
//
// Source of the xcframework, in priority order:
//   1. `Vendor/llama/llama.xcframework` if present — local dev + CI building
//      swift-pwa itself (produced by Scripts/build-llama-xcframework.sh; the
//      dir is gitignored, never committed).
//   2. otherwise the checksummed release asset (url) — what adopters get.
if ProcessInfo.processInfo.environment["SWIFT_PWA_LLAMA"] != nil {
    // `CLlama` is sourced differently per build host (Package.swift evaluates on
    // the machine doing the build, so `#if os` discriminates the *backend*):
    //
    //   * Apple (macOS host, incl. iOS cross-builds) → a prebuilt **xcframework**
    //     via `.binaryTarget` (Metal embedded). Local `Vendor/llama` dir if the
    //     build script produced one, else the checksummed release asset.
    //   * Linux/Windows → a `.systemLibrary` over **vendored, committed headers**
    //     (`Vendor/llama-headers/`, same llama.cpp pin as the xcframework). The
    //     prebuilt static lib itself is found at link time via the `LIBRARY_PATH`
    //     (Linux) / `LIB` (Windows) env var the CLI sets — NO `unsafeFlags`,
    //     which would poison version-pinned dependency resolution. Everything
    //     else links through the always-safe `.linkedLibrary`.
    let llamaCTarget: Target
    let llamaLinkerSettings: [LinkerSetting]
    #if os(Linux)
        llamaCTarget = .systemLibrary(name: "CLlama", path: "Vendor/llama-headers")
        llamaLinkerSettings = [
            .linkedLibrary("llama"), // combined static archive: llama + ggml + ggml-vulkan
            .linkedLibrary("stdc++"), // ggml is C++
            .linkedLibrary("vulkan"), // loader (libvulkan.so.1); ICD comes from the GPU driver
            .linkedLibrary("pthread"),
            .linkedLibrary("dl"),
            .linkedLibrary("m")
        ]
    #elseif os(Windows)
        llamaCTarget = .systemLibrary(name: "CLlama", path: "Vendor/llama-headers")
        // `.linkedLibrary("llama")` → `llama.lib`, the combined MSVC static archive
        // the CLI stages onto the `LIB` env path. The MSVC C++ runtime is linked
        // automatically via the objects' default-lib directives, so — unlike
        // Linux's explicit `stdc++` — nothing else is needed. `vulkan-1` →
        // `vulkan-1.lib`, the Vulkan loader import lib, links ONLY for the Vulkan
        // builds (which reference its symbols):
        //   x64   → always Vulkan (mature NVIDIA/AMD/Intel drivers).
        //   arm64 → CPU-only by default (its shipped/pinned lib has NO ggml-vulkan,
        //           so linking vulkan-1 would be a needless dep requiring the SDK).
        //           The EXPERIMENTAL Adreno Vulkan lib (LLAMA_WIN_ARM64_VULKAN in
        //           the build script) DOES reference vulkan-1 — set the same env
        //           var here so it links. (Adreno X1 Vulkan output is currently
        //           garbage — experimental, for re-testing; see docs.)
        // Windows builds are native (host arch == target arch), so `#if arch` here
        // matches the lib the CLI stages.
        #if arch(arm64)
            if ProcessInfo.processInfo.environment["LLAMA_WIN_ARM64_VULKAN"] != nil {
                llamaLinkerSettings = [.linkedLibrary("llama"), .linkedLibrary("vulkan-1")]
            } else {
                llamaLinkerSettings = [.linkedLibrary("llama")]
            }
        #else
            llamaLinkerSettings = [.linkedLibrary("llama"), .linkedLibrary("vulkan-1")]
        #endif
    #else
        let localXcframework = "Vendor/llama/llama.xcframework"
        llamaCTarget = FileManager.default.fileExists(atPath: localXcframework)
            ? .binaryTarget(name: "CLlama", path: localXcframework)
            : .binaryTarget(
                name: "CLlama",
                // Stable, llama-pin-versioned asset (NOT per swift-pwa release):
                // built + published by .github/workflows/llama-xcframework.yml and
                // re-pinned here only when Scripts/build-llama-xcframework.sh bumps
                // the pinned llama.cpp commit. The `url` is stable; the `checksum`
                // moves with the pin. (Local dev / swift-pwa CI use the
                // Vendor/llama path branch above, built by the same script.)
                url: "https://github.com/tophatch/swift-pwa/releases/download/llama-vendor/llama.xcframework.zip",
                checksum: "b88b4797978bc566c63b15a44151b02c8a66245e5cf034dcbb1ace31bc9fbbc5"
            )
        llamaLinkerSettings = [
            // The combined static lib carries its C++ runtime + Metal /
            // Accelerate symbols but not their link directives — the
            // consumer links them. These propagate to the final app.
            .linkedLibrary("c++", .when(platforms: [.macOS, .iOS])),
            .linkedFramework("Metal", .when(platforms: [.macOS, .iOS])),
            .linkedFramework("MetalKit", .when(platforms: [.macOS, .iOS])),
            .linkedFramework("Accelerate", .when(platforms: [.macOS, .iOS]))
        ]
    #endif

    package.products.append(.library(name: "SwiftPWALlama", targets: ["SwiftPWALlama"]))
    package.targets.append(contentsOf: [
        llamaCTarget,
        .target(
            name: "SwiftPWALlama",
            dependencies: ["SwiftPWACore", "SwiftPWAModelStore", "CLlama"],
            swiftSettings: swiftSettings,
            linkerSettings: llamaLinkerSettings
        ),
        .testTarget(
            name: "SwiftPWALlamaTests",
            dependencies: ["SwiftPWALlama", "SwiftPWACore", "SwiftPWAModelStore"],
            swiftSettings: swiftSettings
        )
    ])
}

// MARK: - Optional ONNX Runtime packaging spike (env-gated, Apple + Android)

// SPIKE, not a shipped backend. De-risks the packaging story for the 0.8
// ONNX Runtime tier (first consumer: `ai.vision.*` / MobileSAM segmentation
// — see docs/proposals/segmentation-plugin.md) before investing in the
// actual encoder/decoder backend. The smoke targets below link the real
// vendored artifact and call one real C API function (`OrtGetApiBase`);
// they prove the artifact/link/import chain works and nothing more.
//
// **Apple** mirrors the llama.cpp `.binaryTarget` pattern above exactly,
// but the upstream artifact needs a repackaging step first: Microsoft's
// official Apple distribution (no GitHub Release asset — the stable,
// versioned download lives on Microsoft's own CDN, the same artifact
// `onnxruntime-swift-package-manager` vendors internally) ships each slice
// as a versioned `.framework` *bundle* with no `Modules/module.modulemap`,
// so `import onnxruntime` doesn't work out of the box — yet the binary
// inside is a plain static archive (`ar` format), not a dylib.
// `Scripts/vendor-onnxruntime-apple.sh` extracts the static lib + headers
// from each slice and re-packages them via `xcodebuild -create-xcframework
// -library -headers` into the same flat-library-plus-headers shape
// `Vendor/llama-headers` already uses. Verified end-to-end: the script's
// output actually links and its C API is callable
// (`SwiftPWAONNXRuntimeSmokeTests`).
//
// **Android** has a real prebuilt artifact too (unlike llama.cpp, which has
// no Android backend at all in this repo): the `onnxruntime-android` AAR on
// Maven Central bundles the plain C API headers directly plus a per-ABI
// `libonnxruntime.so` (Microsoft's own JNI glue, `libonnxruntime4j_jni.so`,
// isn't needed — Swift calls the C API directly, no JVM round-trip).
// `Scripts/vendor-onnxruntime-android.sh` downloads + sha1-verifies the AAR
// (against Maven's own published sidecar) and extracts both. Mirrors
// `Vendor/llama-headers`' off-Apple shape exactly: headers committed under
// `Vendor/onnxruntime-android-headers/` (a plain `.systemLibrary`, no
// pkgConfig — host-agnostic to declare, so it isn't wrapped in an `#if os`
// guard below), the `.so` itself gitignored under `Vendor/onnxruntime-
// android/<abi>/` and found at cross-compile link time via `LIBRARY_PATH`
// (clang's Android cross-linker driver honors it exactly like the host
// one — no `unsafeFlags`). Verified end-to-end, including on-device: a
// throwaway executable target linked against the vendored
// `libonnxruntime.so` via `swift build --swift-sdk
// aarch64-unknown-linux-android28` (`nm -D` shows `OrtGetApiBase` as an
// undefined symbol versioned `VERS_1.27.0`, i.e. resolving against the
// real lib, not a stub), pushed + run via `adb shell` on a Galaxy Tab
// S10+ (arm64-v8a) → printed the real version string `"1.27.0"`.
// `SwiftPWAONNXRuntimeAndroidSmoke` itself is a plain library target (no
// product yet forces a real link on it — that arrives with a real
// backend/example app), so it's a compile+module-resolution check; the
// throwaway executable above is what proved the link+runtime story.
//
// Linux/Windows still have no ONNX Runtime backend story — not part of
// this spike. Not part of either spike: a real segmentation backend, and
// publishing either vendored artifact as a release asset (the CLI-side
// fetch to make that automatic for adopters, `LlamaLinuxArtifact`-style,
// is a documented follow-up).
if ProcessInfo.processInfo.environment["SWIFT_PWA_ONNXRUNTIME"] != nil {
    #if os(macOS)
        let localOnnxXcframework = "Vendor/onnxruntime/onnxruntime.xcframework"
        let onnxRuntimeTarget: Target = FileManager.default.fileExists(atPath: localOnnxXcframework)
            ? .binaryTarget(name: "ONNXRuntime", path: localOnnxXcframework)
            // PENDING: no swift-pwa release has published a
            // `onnxruntime.xcframework.zip` asset yet (the llama.cpp
            // equivalent of `.github/workflows/llama-xcframework.yml` +
            // its release asset is a follow-up, not part of this spike).
            // Until then this branch is unreachable for anyone without a
            // local `Vendor/onnxruntime/` — run
            // `Scripts/vendor-onnxruntime-apple.sh` to produce one.
            : .binaryTarget(
                name: "ONNXRuntime",
                url: "https://github.com/tophatch/swift-pwa/releases/download/onnxruntime-vendor/onnxruntime.xcframework.zip",
                checksum: "81ba4127ecf3ebfc713275e8b36a6692f16a58e6d147f0e99ff58af1cdc74794"
            )

        package.targets.append(contentsOf: [
            onnxRuntimeTarget,
            .target(
                name: "SwiftPWAONNXRuntimeSmoke",
                dependencies: [.target(name: "ONNXRuntime", condition: .when(platforms: [.macOS, .iOS]))],
                swiftSettings: swiftSettings
            ),
            .testTarget(
                name: "SwiftPWAONNXRuntimeSmokeTests",
                dependencies: ["SwiftPWAONNXRuntimeSmoke"],
                swiftSettings: swiftSettings
            )
        ])
    #else
        // Linux / Windows: the desktop ONNX Runtime target (`ONNXRuntimeDesktop`,
        // a `.systemLibrary` over committed headers) is declared host-agnostically
        // below alongside the Android one — same reasoning: a systemLibrary over
        // committed headers is safe to put in the graph on any host, and the
        // actual `libonnxruntime.so` / `onnxruntime.dll`+`.lib` is found at link
        // time via `LIBRARY_PATH` / `LIB` (Microsoft's prebuilt CPU build,
        // vendored by Scripts/vendor-onnxruntime-{linux,windows}.sh).
    #endif

    // Android — host-agnostic to declare (a plain `.systemLibrary` over
    // committed headers, like `CLlama` on Linux), so no `#if os` guard:
    // this builds correctly regardless of which host (macOS or Linux) runs
    // the Android cross-compile.
    package.targets.append(contentsOf: [
        .systemLibrary(name: "ONNXRuntimeAndroid", path: "Vendor/onnxruntime-android-headers"),
        .target(
            name: "SwiftPWAONNXRuntimeAndroidSmoke",
            dependencies: [.target(name: "ONNXRuntimeAndroid", condition: .when(platforms: [.android]))],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedLibrary("onnxruntime", .when(platforms: [.android]))]
        )
    ])

    // Desktop (Linux x86_64 + Windows x64) — a plain `.systemLibrary` over the
    // same committed C API headers (module `ONNXRuntimeDesktop`; the headers
    // are identical to the Android release's, just a separate modulemap dir).
    // Host-agnostic to declare, like `ONNXRuntimeAndroid`. The `.so`/`.dll`+
    // `.lib` are Microsoft's prebuilt **CPU** desktop build (vendored by
    // Scripts/vendor-onnxruntime-{linux,windows}.sh), found at link time via
    // `LIBRARY_PATH` (Linux) / `LIB` (Windows) — the same env-search mechanism
    // SwiftPWALlama uses off-Apple, never `unsafeFlags`.
    package.targets.append(contentsOf: [
        .systemLibrary(name: "ONNXRuntimeDesktop", path: "Vendor/onnxruntime-desktop-headers"),
        .target(
            name: "SwiftPWAONNXRuntimeDesktopSmoke",
            dependencies: [.target(name: "ONNXRuntimeDesktop", condition: .when(platforms: [.linux, .windows]))],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedLibrary("onnxruntime", .when(platforms: [.linux, .windows]))]
        )
    ])

    // MARK: - Segmentation backend (ai.vision.*, MobileSAM via ONNX Runtime)

    // The real consumer of the ONNX Runtime tier: `MobileSAMBackend`
    // conforms to Core's `SegmentationBackend` (see
    // docs/proposals/segmentation-plugin.md). Apple + Android. Declared
    // host-agnostically (like `ONNXRuntimeAndroid` above) so an Android
    // cross-compile from either a macOS or a Linux host sees this target —
    // "ONNXRuntime" (the Apple xcframework binaryTarget) is only referenced
    // by name when it was actually declared above (a macOS-describing
    // host), since SwiftPM errors on a dependency name that doesn't exist
    // in the graph regardless of platform conditions. On a destination with
    // neither ONNX Runtime linked (Linux/Windows-native), the source itself
    // compiles to an empty stub (see the guard in OrtRuntime.swift).
    // SwiftPWAModelStore (ModelDownloader/ModelSpec) backs the downloadable-
    // model tier (`ai.vision.ensureModel`) — the same resumable, checksum-
    // pinned download machinery SwiftPWALlama uses, modality-agnostic. Plain
    // Foundation, cross-platform, no gating.
    var segmentationDependencies: [Target.Dependency] = ["SwiftPWACore", "SwiftPWAModelStore"]
    #if os(macOS)
        segmentationDependencies.append(.target(name: "ONNXRuntime", condition: .when(platforms: [.macOS, .iOS])))
    #endif
    segmentationDependencies.append(contentsOf: [
        .target(name: "ONNXRuntimeAndroid", condition: .when(platforms: [.android])),
        .target(name: "SwiftPWAAndroid", condition: .when(platforms: [.android])),
        .target(name: "ONNXRuntimeDesktop", condition: .when(platforms: [.linux, .windows])),
        // Desktop has no CoreGraphics (Apple) or BitmapFactory-over-RPC
        // (Android) to decode/resize an image, so a tiny vendored stb_image
        // C target does it (see Sources/CStbImage). Linux/Windows only.
        .target(name: "CStbImage", condition: .when(platforms: [.linux, .windows]))
    ])

    package.products.append(.library(name: "SwiftPWASegmentation", targets: ["SwiftPWASegmentation"]))
    package.targets.append(contentsOf: [
        // Vendored stb_image (single-header, public-domain) — the desktop
        // image decoder (Linux/Windows have no CoreGraphics / BitmapFactory).
        // Compiled only where SwiftPWASegmentation depends on it (linux/windows).
        .target(name: "CStbImage", path: "Sources/CStbImage", publicHeadersPath: "include"),
        .target(
            name: "SwiftPWASegmentation",
            dependencies: segmentationDependencies,
            swiftSettings: swiftSettings,
            linkerSettings: [
                .linkedLibrary("onnxruntime", .when(platforms: [.android, .linux, .windows])),
                // The vendored ONNX Runtime xcframework embeds protobuf (C++),
                // which needs libc++ (Arena, exception-personality symbols). A
                // `.binaryTarget` can't declare linker settings, so we hang it
                // on this regular target instead — SwiftPM propagates a target's
                // linkerSettings to the final executable link, so any app that
                // links SwiftPWASegmentation gets libc++ automatically (a plain
                // `.executableTarget` doesn't pull it in by default the way a
                // test bundle incidentally does). Without this, a consuming app
                // hits unresolved `___gxx_personality_v0` / protobuf symbols and
                // has to add the flag itself.
                .linkedLibrary("c++", .when(platforms: [.macOS, .iOS]))
            ]
        ),
        .testTarget(
            name: "SwiftPWASegmentationTests",
            dependencies: ["SwiftPWASegmentation", "SwiftPWACore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        )
    ])
}

// MARK: - Optional Windows Phi Silica backend (env-gated, Windows App SDK)

// `SwiftPWAPhiSilica` / `PhiSilicaBackend` exposes Windows Phi Silica (the
// Windows AI APIs in the Windows App SDK) through the `ai.*` plugin — the
// Windows tier-1 platform built-in, like Apple Foundation Models and Android
// Gemini Nano. It's env-gated (NOT in the umbrella) because the `CPhiSilica`
// C++/WinRT shim links the **Windows App SDK** — its cppwinrt projection
// headers must be on INCLUDE and the bootstrapper lib on LIB, and the runtime
// redistributable present at launch (see docs/windows-setup.md). Apps that
// don't want on-device AI shouldn't take that dependency.
//
// `swift-pwa build --target windows` sets `SWIFT_PWA_PHI_SILICA=1` from
// `ai.phi_silica: true` in pwa.json (the adopter never sets it by hand), at
// which point this block adds the target/product. When unset, neither the
// shim nor the Windows App SDK linkage is in the graph.
//
// BOX-PENDING: the exact Windows App SDK include/lib names + the bootstrapper
// lib are confirmed on the Copilot+ verify box (bsp12in, arm64 NPU) — the
// `linkerSettings` below are the starting point.
if ProcessInfo.processInfo.environment["SWIFT_PWA_PHI_SILICA"] != nil {
    package.products.append(.library(name: "SwiftPWAPhiSilica", targets: ["SwiftPWAPhiSilica"]))
    package.targets.append(contentsOf: [
        .target(
            name: "CPhiSilica",
            path: "Sources/CPhiSilica",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("UNICODE", .when(platforms: [.windows])),
                .define("_UNICODE", .when(platforms: [.windows])),
                .define("WIN32_LEAN_AND_MEAN", .when(platforms: [.windows]))
            ],
            linkerSettings: [
                // C++/WinRT dispatch (built-in WinRT) goes through
                // WindowsApp.lib; the Windows App SDK bootstrapper import lib
                // (`Microsoft.WindowsAppRuntime.Bootstrap.lib`) is staged onto
                // LIB by the CLI alongside the SDK headers on INCLUDE.
                .linkedLibrary("WindowsApp", .when(platforms: [.windows])),
                .linkedLibrary("Microsoft.WindowsAppRuntime.Bootstrap", .when(platforms: [.windows]))
            ]
        ),
        .target(
            name: "SwiftPWAPhiSilica",
            dependencies: [
                "SwiftPWACore",
                .target(name: "CPhiSilica", condition: .when(platforms: [.windows]))
            ],
            swiftSettings: swiftSettings
        )
    ])
}
