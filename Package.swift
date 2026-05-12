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
        .library(name: "SwiftPWATestSupport", targets: ["_SwiftPWATestSupport"]),
        .executable(name: "swift-pwa", targets: ["swift-pwa-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // swift-crypto gives the `swift-pwa updater` CLI subcommands an
        // Ed25519 implementation that works on Linux and Windows hosts
        // too — CryptoKit is Apple-only, but `import Crypto` from
        // swift-crypto presents an API-compatible surface across
        // platforms (and on Apple it just shadows CryptoKit). The CLI
        // is the only consumer; the runtime side stays on CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0" ..< "5.0.0")
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
        gtkBackendTarget
    ] + (appIndicatorSystemLibraryTarget.map { [$0] } ?? []) + [
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
                .target(name: "SwiftPWAWindows", condition: .when(platforms: [.windows]))
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
