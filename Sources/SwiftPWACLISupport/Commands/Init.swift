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

    @Flag(
        help: """
        Force adopt-in-place: add only the native shell (Package.swift + Sources/), leave an \
        existing web/ untouched, and merge missing fields into an existing pwa.json instead of \
        refusing to overwrite it. This is auto-detected when the target directory already has a \
        pwa.json or web/ — pass the flag to force it for a frontend in a non-standard layout.
        """
    )
    var inPlace: Bool = false

    func run() async throws {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        // Resolve where the project lives. An explicit --path is used
        // verbatim. Otherwise, if the *current directory* already looks
        // like a web app (a pwa.json or web/ is present), adopt it in
        // place — the natural "cd into my web app, run init" flow — rather
        // than nesting a <name>/ subdirectory inside it. Only a directory
        // with neither gets the fresh-project <name>/ subdir default.
        let root: URL = if let explicitPath = path {
            URL(fileURLWithPath: explicitPath)
        } else if fm.fileExists(atPath: cwd.appendingPathComponent("pwa.json").path)
            || fm.fileExists(atPath: cwd.appendingPathComponent("web").path)
        {
            cwd
        } else {
            cwd.appendingPathComponent(name)
        }

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

        let id = bundleId ?? "com.example.\(identifier.lowercased())"

        // Adopt-in-place when the target directory already looks like a web
        // app — a pwa.json or a web/ already there means the user is
        // wrapping an existing frontend, not scaffolding a blank project.
        // The `--in-place` flag forces the same mode for a frontend in a
        // non-standard layout (e.g. a custom `dist/` with no pwa.json yet).
        let pwaURL = root.appendingPathComponent("pwa.json")
        let hasExistingManifest = fm.fileExists(atPath: pwaURL.path)
        let hasExistingWeb = fm.fileExists(atPath: root.appendingPathComponent("web").path)
        let adopt = inPlace || hasExistingManifest || hasExistingWeb
        if adopt, !inPlace {
            let signal = hasExistingManifest ? "pwa.json" : "web/"
            print("note: found existing \(signal) in \(root.path) — adopting in place (adding only the native shell).")
        }

        // The native shell — Package.swift + the Swift sources — is what
        // `init` always owns. pwa.json / web/ / .gitignore are "soft": when
        // adopting we merge / leave them alone rather than treating a
        // pre-existing one as a fatal conflict, so an adopted web app keeps
        // its frontend and hand-tuned manifest. Otherwise every file is a
        // conflict (the original behavior), which still lets `--path .`
        // scaffold next to an existing README / .git.
        let nativeShellPaths = [
            "Package.swift",
            "Sources/\(identifier)/App.swift",
            "Sources/\(identifier)/AndroidEntry.swift"
        ]
        let softPaths = ["pwa.json", "web/index.html", ".gitignore"]
        let conflicts = (adopt ? nativeShellPaths : nativeShellPaths + softPaths).filter {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        if !conflicts.isEmpty {
            throw ValidationError(
                "Refusing to overwrite existing files in \(root.path):\n  - "
                    + conflicts.joined(separator: "\n  - ")
                    + (adopt ? "\n(adopt-in-place adds only the native shell; remove the above to re-scaffold.)" : "")
            )
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("Sources/\(identifier)"),
            withIntermediateDirectories: true
        )

        // Resolve the manifest that drives the generated App.swift window
        // config + Package.swift target name. When adopting an existing
        // pwa.json we merge into the user's file (preserving everything
        // they set) rather than overwriting it; otherwise we write a fresh
        // one.
        let manifest: PWAManifest
        if adopt, hasExistingManifest {
            manifest = try Self.mergeIntoExistingManifest(
                at: pwaURL, identifier: identifier, displayName: displayName, id: id
            )
            print("Merged missing fields into existing \(pwaURL.lastPathComponent) (existing values kept).")
        } else {
            manifest = Self.freshManifest(identifier: identifier, displayName: displayName, id: id)
            try manifest.write(to: pwaURL)
        }

        try Templates.packageSwift(name: identifier).write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try Templates.mainSwift(structName: identifier, window: manifest.window).write(
            to: root.appendingPathComponent("Sources/\(identifier)/App.swift"),
            atomically: true,
            encoding: .utf8
        )
        try Templates.androidEntrySwift(name: identifier, packageId: manifest.android?.packageId ?? id).write(
            to: root.appendingPathComponent("Sources/\(identifier)/AndroidEntry.swift"),
            atomically: true,
            encoding: .utf8
        )

        // web/ + starter index.html: only when we're not adopting an
        // existing frontend. An existing web/ (the --in-place case) is
        // left exactly as-is; if there's no web/ at all we still drop a
        // starter page so `build` has something to bundle.
        let webDir = root.appendingPathComponent(manifest.web.directory)
        if !fm.fileExists(atPath: webDir.path) {
            try fm.createDirectory(at: webDir, withIntermediateDirectories: true)
            try Templates.indexHTML(name: displayName).write(
                to: webDir.appendingPathComponent(manifest.web.entry),
                atomically: true,
                encoding: .utf8
            )
        }

        // `.gitignore` covers the conventional Swift / bundling artifacts
        // plus the Android signing material that should never be checked
        // in. Don't clobber an existing one (common in an adopted repo).
        let gitignoreURL = root.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: gitignoreURL.path) {
            try Self.gitignoreTemplate.write(to: gitignoreURL, atomically: true, encoding: .utf8)
        }

        print(adopt ? "Added native shell to \(root.path)" : "Created \(root.path)")
        if root.standardizedFileURL == cwd.standardizedFileURL {
            print("Next: swift run swift-pwa build --target macos")
        } else {
            print("Next: cd \(root.lastPathComponent) && swift run swift-pwa build --target macos")
        }
    }

    /// The default manifest for a brand-new project. `name` is the
    /// human-facing display string (window title / Finder label) and may
    /// contain spaces; `executableName` is the SwiftPM target name (the
    /// sanitized identifier) and is only emitted when it differs from
    /// `name`, so an all-identifier-safe name like "MyApp" produces a
    /// clean manifest with no redundant `executable_name`.
    static func freshManifest(identifier: String, displayName: String, id: String) -> PWAManifest {
        PWAManifest(
            id: id,
            name: displayName,
            executableName: identifier == displayName ? nil : identifier,
            version: "0.1.0",
            description: nil,
            icon: nil,
            web: .init(directory: "web", entry: "index.html"),
            window: .init(title: displayName),
            macos: .init(bundleIdentifier: id, category: nil, minimumSystemVersion: "15.0"),
            ios: .init(bundleIdentifier: id, minimumSystemVersion: "18.0"),
            linux: .init(desktopCategories: ["Utility"], executableName: nil),
            android: .init(
                packageId: id,
                minSdk: 28,
                targetSdk: 34,
                abis: ["arm64-v8a", "x86_64"],
                versionCode: 1
            )
        )
    }

    /// Shallow-merge the defaults a fresh project would get into the
    /// user's existing `pwa.json`, *adding only top-level keys that are
    /// absent* — everything the user already set is preserved verbatim,
    /// including any keys outside our schema. Operates on the raw JSON
    /// object (not a Codable round-trip) precisely so unknown / hand-added
    /// fields survive.
    ///
    /// One field is force-set rather than merge-if-absent:
    /// `executable_name`. `init` generates `Package.swift` with the
    /// SwiftPM target named after `identifier`, so the bundler must look
    /// for `.build/release/<identifier>`. If the user's existing `name`
    /// isn't that identifier (e.g. it has spaces), we pin
    /// `executable_name` to `identifier` so the two can't silently drift.
    /// Writes the merged object back and returns it decoded.
    static func mergeIntoExistingManifest(
        at url: URL, identifier: String, displayName: String, id: String
    ) throws -> PWAManifest {
        let existingData = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            throw ValidationError("\(url.path) is not a JSON object — can't merge --in-place.")
        }

        let defaults = freshManifest(identifier: identifier, displayName: displayName, id: id)
        let defaultsData = try {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return try encoder.encode(defaults)
        }()
        let defaultsObject = try (JSONSerialization.jsonObject(with: defaultsData) as? [String: Any]) ?? [:]

        for (key, value) in defaultsObject where object[key] == nil {
            object[key] = value
        }

        // Pin executable_name to the generated SwiftPM target name unless
        // the user already declared one or their `name` is already exactly
        // the identifier (in which case binaryName == name == identifier).
        if object["executable_name"] == nil, (object["name"] as? String) != identifier {
            object["executable_name"] = identifier
        }

        let merged = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try merged.write(to: url)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PWAManifest.self, from: merged)
    }

    /// `.gitignore` body. `*.jks` / `*.keystore` / `*.p12` cover the three
    /// keytool output formats; `keystore.properties` covers the convention
    /// some teams use to stash passwords on disk (we read passwords from
    /// env vars in the generated Gradle scaffold, but the file is still
    /// common in mixed toolchains).
    static let gitignoreTemplate = """
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

    """

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
                .package(url: "https://github.com/tophatch/swift-pwa", from: "\(SwiftPWAVersion.current)"),
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

    static func mainSwift(structName: String, window: PWAManifest.WindowSection) -> String {
        // Escape the window title for safe embedding in the generated
        // Swift source. `window.title` is whatever the user typed, which
        // can legitimately contain quotes / backslashes.
        let titleLiteral = window.title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Drop a trailing `.0` so 1024.0 reads as 1024 in the source.
        let width = String(format: "%g", window.width)
        let height = String(format: "%g", window.height)
        let name = structName
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

            // This WindowConfig is the *runtime* source of truth for the
            // window — pwa.json's `window` block only seeds these values
            // at `swift-pwa init` time and is otherwise build metadata, so
            // editing pwa.json later has no effect on the running app.
            // Change the window here, or keep the two in sync by hand.
            _ = try ctx.createWindow(WindowConfig(
                title: "\(titleLiteral)",
                size: Size(width: \(width), height: \(height)),
                resizable: \(window.resizable),
                fullscreen: \(window.fullscreen),
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
