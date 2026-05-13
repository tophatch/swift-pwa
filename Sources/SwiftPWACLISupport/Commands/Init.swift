import ArgumentParser
import Foundation

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Scaffold a new swift-pwa project."
    )

    @Argument(help: "Project name (also used as the directory name).")
    var name: String

    @Option(help: "Reverse-DNS identifier for the app, e.g. com.example.hello.")
    var bundleId: String?

    @Option(help: "Directory to create the project in. Defaults to current dir + name.")
    var path: String?

    func run() async throws {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let root = path.map { URL(fileURLWithPath: $0) } ?? cwd.appendingPathComponent(name)

        // The argument we got is what the user wants to *see* (window
        // title, About panel). But it also has to double as a SwiftPM
        // target name and a Swift type name — `Package.swift`'s
        // `name:`, the `Sources/<name>/` directory, the `@main struct`,
        // and `pwa.json`'s `name` (which the bundler uses to locate
        // `.build/release/<name>` and produce `<name>.app`) all share
        // one string today. So normalise the user input to a valid
        // Swift identifier for those four uses, and keep the original
        // as a display string for the window title.
        let identifier = try Self.sanitizeIdentifier(name)
        if identifier != name {
            print(
                "note: normalised project name '\(name)' → '\(identifier)' (Swift identifiers can't contain '-' / spaces)"
            )
        }
        let displayName = name

        // Per-file conflict check rather than "directory exists": this lets
        // `--path .` scaffold alongside an existing README / LICENSE / .git
        // dir, while still refusing to silently clobber a real swift-pwa
        // project's Package.swift / pwa.json.
        let relPathsToWrite = [
            "pwa.json",
            "Package.swift",
            "Sources/\(identifier)/App.swift",
            "Sources/\(identifier)/AndroidEntry.swift",
            "web/index.html",
            ".gitignore"
        ]
        let conflicts = relPathsToWrite.filter {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        if !conflicts.isEmpty {
            throw ValidationError(
                "Refusing to overwrite existing files in \(root.path):\n  - "
                    + conflicts.joined(separator: "\n  - ")
            )
        }

        let id = bundleId ?? "com.example.\(identifier.lowercased())"
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("Sources/\(identifier)"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: true)

        let android = PWAManifest.AndroidSection(
            packageId: id,
            minSdk: 28,
            targetSdk: 34,
            abis: ["arm64-v8a", "x86_64"],
            versionCode: 1
        )

        // `manifest.name` doubles as the SwiftPM target name today: the
        // bundlers locate `.build/release/<manifest.name>` and produce
        // `<manifest.name>.app`. So it has to track `identifier`, not
        // the user's display string. The window title is the place that
        // surfaces the original.
        let manifest = PWAManifest(
            id: id,
            name: identifier,
            version: "0.1.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web", entry: "index.html"),
            window: .init(title: displayName),
            macos: .init(bundleIdentifier: id, category: nil, minimumSystemVersion: "15.0"),
            ios: .init(bundleIdentifier: id, minimumSystemVersion: "18.0"),
            linux: .init(desktopCategories: ["Utility"], executableName: nil),
            android: android
        )
        try manifest.write(to: root.appendingPathComponent("pwa.json"))

        try Templates.packageSwift(name: identifier).write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try Templates.mainSwift(name: identifier, displayName: displayName).write(
            to: root.appendingPathComponent("Sources/\(identifier)/App.swift"),
            atomically: true,
            encoding: .utf8
        )
        try Templates.androidEntrySwift(name: identifier, packageId: id).write(
            to: root.appendingPathComponent("Sources/\(identifier)/AndroidEntry.swift"),
            atomically: true,
            encoding: .utf8
        )
        try Templates.indexHTML(name: displayName).write(
            to: root.appendingPathComponent("web/index.html"),
            atomically: true,
            encoding: .utf8
        )
        // `.gitignore` covers the conventional Swift / bundling
        // artifacts plus the Android signing material that should
        // never be checked in. `*.jks` / `*.keystore` / `*.p12` cover
        // the three keytool output formats; `keystore.properties`
        // covers the convention some teams use to stash passwords on
        // disk (we read passwords from env vars in the generated
        // Gradle scaffold, but the file is still common in mixed
        // toolchains).
        try """
        .build/
        DerivedData/
        build/
        *.app
        *.ipa
        *.AppImage
        *.jks
        *.keystore
        *.p12
        keystore.properties

        """.write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        print("Created \(root.path)")
        if root.standardizedFileURL == cwd.standardizedFileURL {
            print("Next: swift run swift-pwa build --target macos")
        } else {
            print("Next: cd \(root.lastPathComponent) && swift run swift-pwa build --target macos")
        }
    }

    /// Convert the user's project name into a valid Swift identifier
    /// for use as a SwiftPM target / source directory / `@main` struct.
    /// Splits on any non-alphanumeric character and joins back as
    /// camelCase: `test-app` → `testApp`, `my cool app` → `myCoolApp`.
    /// A leading digit prefixes an underscore (`3d-viewer` → `_3dViewer`).
    /// Errors out if there are no alphanumeric characters at all
    /// (`---`) rather than silently producing the empty string.
    static func sanitizeIdentifier(_ raw: String) throws -> String {
        let pieces = raw
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !pieces.isEmpty else {
            throw ValidationError(
                "Project name '\(raw)' contains no letters or digits — pick something usable as a Swift identifier."
            )
        }
        var result = pieces[0]
        // Preserve the user's original case on the first piece (so
        // `MyApp` doesn't get re-cased), only lowercasing it if it
        // starts with something that's not already a valid Swift
        // identifier head (currently just leading-digit handling).
        if let first = result.first, first.isNumber {
            result = "_" + result
        }
        for piece in pieces.dropFirst() {
            result += piece.prefix(1).uppercased() + piece.dropFirst()
        }
        return result
    }
}

enum Templates {
    static func packageSwift(name: String) -> String {
        """
        // swift-tools-version:6.0
        import PackageDescription

        let package = Package(
            name: "\(name)",
            platforms: [.macOS(.v15), .iOS(.v18)],
            dependencies: [
                .package(url: "https://github.com/tophatch/swift-pwa", from: "0.1.0"),
            ],
            targets: [
                .executableTarget(
                    name: "\(name)",
                    dependencies: [
                        .product(name: "SwiftPWA", package: "swift-pwa"),
                    ],
                    linkerSettings: [
                        // On Android, the Swift binary is loaded by the
                        // generated Kotlin Activity via `System.loadLibrary`,
                        // so it has to be a shared object (.so) rather than an
                        // ELF executable. SwiftPM doesn't expose a "build this
                        // executable target as a shared library" knob, so we
                        // inject the linker flags directly. `-no-pie` cancels
                        // the toolchain's default `-pie` (which is mutually
                        // exclusive with `-shared` under `lld`); `-shared`
                        // produces the actual .so.
                        .unsafeFlags(
                            ["-Xlinker", "-no-pie", "-Xlinker", "-shared"],
                            .when(platforms: [.android])
                        ),
                    ]
                ),
            ]
        )
        """
    }

    static func mainSwift(name: String, displayName: String) -> String {
        // Escape the display string for safe embedding in the
        // generated Swift source. The CLI only sanitises `name` to a
        // valid identifier; `displayName` is whatever the user typed,
        // which can legitimately contain quotes / backslashes.
        let titleLiteral = displayName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        import Foundation
        import SwiftPWA

        // `@main` is the desktop entry point. On Android the .so is
        // loaded by the generated Kotlin Activity via
        // `System.loadLibrary`, and `AndroidEntry.swift`'s JNI shim
        // calls `configure(_:)` directly — `main()` here is unreachable
        // on Android but still emitted so SwiftPM's linker can resolve
        // its `--defsym=main=...` indirection.
        @main
        struct \(name)App {
            static func main() async throws {
                let runtime = try SwiftPWA.runtime()
                try runtime.run(configure)
            }
        }

        @MainActor
        func configure(_ ctx: any AppContext) throws {
            // On Android the WebView resolves bundled assets via the
            // virtual `https://swift-pwa.local/` host — see
            // SwiftPWAAndroid's WebViewAssetLoader. On desktop the
            // bundled web/ ships inside the resource bundle:
            //   - macOS: <App>.app/Contents/Resources/web
            //   - iOS:   <App>.app/web
            //   - Linux: usr/share/<exe>/web (AppImage; not Bundle-resolvable)
            //   - Windows: alongside the .exe
            // `resourceURL` is the cross-platform answer for Apple
            // (it points at `Contents/Resources/` on macOS and at the
            // bundle root on iOS); fall back to `bundleURL` for hosts
            // where corelibs-foundation doesn't synthesise one.
            #if os(Android)
                let webRoot = URL(fileURLWithPath: "/android_asset/web")
            #else
                let webRoot = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
                    .appendingPathComponent("web")
                if !FileManager.default.fileExists(atPath: webRoot.path) {
                    // Fail loudly rather than hand a blank window to the
                    // user: the WKWebView / WebKitGTK / WebView2 schemes
                    // all surface "missing index.html" as a silently
                    // blank page, which is the hardest possible thing
                    // to debug.
                    fatalError("swift-pwa: web bundle not found at \\(webRoot.path) — did the bundler copy `web/` into Resources?")
                }
            #endif

            _ = try ctx.createWindow(WindowConfig(
                title: "\(titleLiteral)",
                size: Size(width: 1024, height: 768),
                content: WindowContent.bundled(directory: webRoot)
            ))
        }
        """
    }

    /// JNI entry-point boilerplate. The exported symbol's name has to
    /// embed the user's Java package id (with dots replaced by
    /// underscores) — SwiftPM doesn't know about the package id, so
    /// this file lives in the user's project. Apps that change
    /// `pwa.json`'s `android.package_id` after `init` must update the
    /// `@_cdecl` string in lockstep — keep them in sync or the
    /// Activity surfaces `UnsatisfiedLinkError: Native method not
    /// found` at startup.
    static func androidEntrySwift(name: String, packageId: String) -> String {
        let mangled = packageId.replacingOccurrences(of: ".", with: "_")
        return """
        #if os(Android)
            import Foundation
            import SwiftPWA

            /// JNI entry point for the generated `MainActivity.swiftPwaMain()`
            /// Kotlin declaration. The symbol name is mangled per JNI's
            /// rules (`Java_<package>_<class>_<method>`, dots → underscores)
            /// and must stay in lockstep with `pwa.json`'s `android.package_id`.
            ///
            /// Called from the worker thread the activity spawns. The
            /// Android backend's `run` blocks this thread on a semaphore
            /// until `quit(exitCode:)` is invoked, so this function
            /// never returns under normal operation.
            @_cdecl("Java_\(mangled)_MainActivity_swiftPwaMain")
            public func swiftpwa_\(name)_android_main(
                _ env: OpaquePointer?,
                _ thiz: OpaquePointer?
            ) {
                _ = env
                _ = thiz

                // `AppRuntime.run(_:)` is `@MainActor`-isolated by the
                // protocol. On Android, MainActor is backed by libdispatch's
                // main queue and `assumeIsolated` is strictly enforced via
                // `dispatch_assert_queue(main)` — so we construct the
                // concrete `AndroidAppRuntime` directly to use its
                // `nonisolated` `run` declaration. Routing through
                // `SwiftPWA.runtime()` would erase to `any AppRuntime` and
                // pick the protocol's `@MainActor` witness, which then
                // requires an actor hop the platform can't satisfy.
                let runtime = AndroidAppRuntime()
                do {
                    try runtime.run(configure)
                } catch {
                    swiftPWALog("\(name): caught error during configure: \\(error)")
                }
            }
        #endif
        """
    }

    static func indexHTML(name: String) -> String {
        // HTML-escape the user's display string so a project name like
        // `Foo & <Bar>` doesn't produce broken markup.
        let escaped = name
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8" />
        <title>\(escaped)</title>
        <style>
          body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; }
          button { padding: .5rem 1rem; }
        </style></head>
        <body>
        <h1>Hello, \(escaped)</h1>
        <p>Powered by <a href="https://github.com/tophatch/swift-pwa">swift-pwa</a>.</p>
        <button id="rename">Rename window</button>
        <pre id="log"></pre>
        <script>
          const log = (m) => document.getElementById('log').textContent += m + '\\n';
          document.getElementById('rename').onclick = async () => {
            try {
              await __SWIFT_PWA__.invoke('window.setTitle', { title: 'renamed at ' + new Date().toISOString() });
              log('renamed');
            } catch (e) { log('error: ' + e.message); }
          };
          __SWIFT_PWA__.subscribe('window.subscribe', {}, (e) => log('event: ' + JSON.stringify(e)));
        </script>
        </body></html>
        """
    }
}
