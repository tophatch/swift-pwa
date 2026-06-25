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
        Force adopt-in-place: scaffold into the current directory (not a <name>/ subdir), \
        adding only the native shell (Package.swift + Sources/), leaving an existing web/ \
        untouched, and merging missing fields into an existing pwa.json instead of refusing to \
        overwrite it. This is auto-detected when the current directory already has a pwa.json or \
        web/ — pass the flag to force it for a frontend in a non-standard layout (e.g. a custom \
        dist/ with no pwa.json yet). Ignored if --path is given.
        """
    )
    var inPlace: Bool = false

    @Flag(
        name: .long,
        help: "Don't scaffold a .github/workflows/release.yml (the cloud cross-platform build workflow)."
    )
    var noCiWorkflow: Bool = false

    func run() async throws {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        // Resolve where the project lives (see `resolveRoot`).
        let root = Self.resolveRoot(name: name, cwd: cwd, path: path, inPlace: inPlace) {
            fm.fileExists(atPath: $0.path)
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

        // A GitHub Actions release workflow so a tag push builds every
        // desktop platform in the cloud — no local toolchains. Off with
        // --no-ci-workflow; skipped if the user already has one.
        var wroteCIWorkflow = false
        if !noCiWorkflow {
            let workflow = root.appendingPathComponent(".github/workflows/release.yml")
            if !fm.fileExists(atPath: workflow.path) {
                try fm.createDirectory(
                    at: workflow.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Templates.releaseWorkflowYml(version: SwiftPWAVersion.current)
                    .write(to: workflow, atomically: true, encoding: .utf8)
                wroteCIWorkflow = true
            }
        }

        print(adopt ? "Added native shell to \(root.path)" : "Created \(root.path)")
        if wroteCIWorkflow {
            print("Added .github/workflows/release.yml — push a tag (e.g. v1.0.0) to build all platforms in CI.")
        }
        if root.standardizedFileURL == cwd.standardizedFileURL {
            print("Next: swift run swift-pwa build --target macos")
        } else {
            print("Next: cd \(root.lastPathComponent) && swift run swift-pwa build --target macos")
        }
    }

    /// Decide the directory the project scaffolds into. Resolution order:
    ///
    ///   1. An explicit `--path` is used verbatim (it wins over everything,
    ///      including `--in-place`).
    ///   2. Otherwise scaffold into the **current directory** — adopt in
    ///      place — when either the user forced it with `--in-place` *or*
    ///      the cwd already looks like a web app (a `pwa.json` or `web/` is
    ///      present, the "cd into my web app and run init" flow).
    ///   3. Failing both, a fresh project nests under a `<name>/` subdir.
    ///
    /// `--in-place` belongs in (2), not just the later adopt logic: its
    /// whole purpose is forcing in-place adoption for a frontend in a
    /// non-standard layout (a custom `dist/` with no `pwa.json`/`web/` yet),
    /// which is exactly the case auto-detection can't see — so without this
    /// the flag would still nest under `<name>/`, the opposite of "in place".
    static func resolveRoot(
        name: String, cwd: URL, path: String?, inPlace: Bool, fileExists: (URL) -> Bool
    ) -> URL {
        if let path {
            return URL(fileURLWithPath: path)
        }
        if inPlace
            || fileExists(cwd.appendingPathComponent("pwa.json"))
            || fileExists(cwd.appendingPathComponent("web"))
        {
            return cwd
        }
        return cwd.appendingPathComponent(name)
    }

    /// The default manifest for a brand-new project. `name` is the
    /// human-facing display string (window title / Finder label) and may
    /// contain spaces. We deliberately *don't* emit `executable_name`:
    /// the SwiftPM target is named `identifier` (in the generated
    /// `Package.swift`), and the bundlers discover that from the package
    /// itself, so a redundant `executable_name` in the manifest would
    /// only be noise. `identifier` still drives `Package.swift` /
    /// `Sources/<name>/` / the `@main` struct.
    static func freshManifest(identifier _: String, displayName: String, id: String) -> PWAManifest {
        PWAManifest(
            id: id,
            name: displayName,
            executableName: nil,
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
    /// We don't touch `executable_name`: `init` generates `Package.swift`
    /// with the SwiftPM target named after `identifier`, and the bundlers
    /// discover that target name from the package itself, so an existing
    /// (possibly spaced) `name` doesn't need pinning. Writes the merged
    /// object back and returns it decoded.
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
        // swift-pwa-generated: v\(SwiftPWAVersion.current)
        //
        // This native shell was generated by the swift-pwa CLI. It's yours to
        // edit — but newer CLIs occasionally expect changes here (e.g. the
        // PWA_DEV_SERVER branch below, which `swift-pwa dev` relies on). The
        // stamp above lets `swift-pwa doctor` flag when this file lags the CLI;
        // regenerate by deleting it and re-running `swift-pwa init <name>
        // --in-place` (then review the git diff).
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
            let content: WindowContent
            if let dev = ProcessInfo.processInfo.environment["PWA_DEV_SERVER"],
               let devURL = URL(string: dev) {
                // `swift-pwa dev` runs a live-reload server over your web/
                // (or you can point it at your own Vite/etc. with --server)
                // and sets PWA_DEV_SERVER — load that so edits show up live
                // without a rebuild. Falls through to the bundled assets in
                // a normal build.
                content = .remote(devURL)
            } else {
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
                content = .bundled(directory: webRoot)
            }

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
                content: content
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
        // swift-pwa-generated: v\(SwiftPWAVersion.current)
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

    /// A ready-to-run GitHub Actions release workflow for the *user's*
    /// app. Pushing a `v*` tag builds the desktop targets in the cloud —
    /// no local Swift / MSVC / GTK toolchains — and attaches the
    /// artifacts to a GitHub Release. Each job downloads the prebuilt
    /// `swift-pwa` CLI (pinned to the version that scaffolded the
    /// project) and runs the platform bundler; the toolchain-setup steps
    /// mirror swift-pwa's own validated CI. iOS and Android are left as
    /// commented stubs because they need signing material / a heavy
    /// cross-compile SDK that can't be wired up generically.
    static func releaseWorkflowYml(version: String) -> String {
        let cliBase = "https://github.com/tophatch/swift-pwa/releases/download"
        return """
        # Build and publish your app for every desktop platform on a tag push.
        #
        #   git tag v1.0.0 && git push --tags
        #
        # …builds macOS / Linux / Windows in the cloud and attaches them to a
        # GitHub Release. No local toolchains required. Generated by
        # `swift-pwa init`; tweak freely.
        #
        # If your pwa.json sets `build.prebuild` (a codegen / asset step that
        # produces part of web/), each `swift-pwa build` below runs it
        # automatically — so add a toolchain-setup step (e.g.
        # `- uses: actions/setup-node@v4`) before the build step in any job
        # whose prebuild needs it, or the build will abort.
        name: Release
        on:
          push:
            tags: ["v*"]

        # The swift-pwa CLI version the bundlers run, pinned to the release that
        # scaffolded this project. This one line is the single source for the
        # three download URLs below — bump it when you upgrade swift-pwa.
        env:
          SWIFT_PWA_CLI_VERSION: "v\(version)"

        jobs:
          macos:
            runs-on: macos-15
            steps:
              - uses: actions/checkout@v5
              - name: Install the swift-pwa CLI
                run: |
                  curl -fsSL "\(cliBase)/$SWIFT_PWA_CLI_VERSION/swift-pwa-macos-arm64" -o /usr/local/bin/swift-pwa
                  chmod +x /usr/local/bin/swift-pwa
              - name: Build the macOS app
                run: swift-pwa build --target macos
              - name: Zip the .app (preserves the bundle layout)
                run: |
                  cd build
                  for app in *.app; do ditto -c -k --keepParent "$app" "${app%.app}-macos.zip"; done
              - uses: actions/upload-artifact@v7
                with:
                  name: macos
                  path: build/*-macos.zip
                  if-no-files-found: error

          linux:
            runs-on: ubuntu-24.04
            steps:
              - uses: actions/checkout@v5
              - uses: swift-actions/setup-swift@v2
                with:
                  swift-version: "6.0"
              - name: Install GTK / WebKitGTK + linuxdeploy
                run: |
                  sudo apt-get update
                  sudo apt-get install -y libgtk-3-dev libwebkit2gtk-4.1-dev libayatana-appindicator3-dev
                  curl -fsSL -o /usr/local/bin/linuxdeploy \
                    https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
                  chmod +x /usr/local/bin/linuxdeploy
              - name: Install the swift-pwa CLI
                run: |
                  curl -fsSL "\(cliBase)/$SWIFT_PWA_CLI_VERSION/swift-pwa-linux-x86_64" -o /usr/local/bin/swift-pwa
                  chmod +x /usr/local/bin/swift-pwa
              - name: Build the AppImage
                # linuxdeploy needs a FUSE-less extraction on CI runners.
                run: APPIMAGE_EXTRACT_AND_RUN=1 swift-pwa build --target linux
              - uses: actions/upload-artifact@v7
                with:
                  name: linux
                  path: build/*.AppImage
                  if-no-files-found: error

          windows:
            runs-on: windows-2022
            steps:
              - uses: actions/checkout@v5
              - name: Set up MSVC (x64)
                uses: ilammy/msvc-dev-cmd@v1
                with:
                  arch: x64
              - name: Set up Swift for Windows
                uses: compnerd/gha-setup-swift@main
                with:
                  swift-version: swift-6.1.2-release
                  swift-build: 6.1.2-RELEASE
              - name: Install WebView2 SDK + WIL (NuGet)
                shell: pwsh
                run: |
                  nuget install Microsoft.Web.WebView2 -OutputDirectory packages -ExcludeVersion
                  nuget install Microsoft.Windows.ImplementationLibrary -OutputDirectory packages -ExcludeVersion
                  $wv2 = "$pwd\\packages\\Microsoft.Web.WebView2\\build\\native"
                  $wil = "$pwd\\packages\\Microsoft.Windows.ImplementationLibrary\\include"
                  Add-Content -Path $env:GITHUB_ENV -Value "INCLUDE=$wv2\\include;$wil;$env:INCLUDE"
                  Add-Content -Path $env:GITHUB_ENV -Value "LIB=$wv2\\x64;$env:LIB"
              - name: Install the swift-pwa CLI
                shell: pwsh
                run: |
                  curl.exe -fsSL "\(cliBase)/$env:SWIFT_PWA_CLI_VERSION/swift-pwa-windows-x86_64.exe" -o swift-pwa.exe
              - name: Build the Windows bundle
                run: .\\swift-pwa.exe build --target windows
              - name: Zip the portable bundle
                shell: pwsh
                run: Get-ChildItem build -Directory | ForEach-Object { Compress-Archive -Path $_.FullName -DestinationPath "build/$($_.Name)-windows.zip" -Force }
              - uses: actions/upload-artifact@v7
                with:
                  name: windows
                  path: build/*-windows.zip
                  if-no-files-found: error

          # ── iOS (opt-in) ────────────────────────────────────────────────
          # iOS needs an Apple signing identity + provisioning profile, which
          # can't be wired up generically. Once you've added your signing
          # secrets, enable a job that runs on macos-15 and:
          #   swift-pwa build --target ios --sign "Apple Distribution: …"
          # See docs/ios-setup.md.
          #
          # ── Android (opt-in) ────────────────────────────────────────────
          # Android needs the Swift Android SDK + NDK cross-compile toolchain.
          # See docs/android-setup.md for the full CI recipe (Swiftly, NDK,
          # swift-android-sdk, JDK 17), then run:
          #   swift-pwa build --target android --cross-compile-android

          release:
            needs: [macos, linux, windows]
            runs-on: ubuntu-24.04
            permissions:
              contents: write
            steps:
              - uses: actions/download-artifact@v8
                with:
                  path: dist
              - name: Publish the GitHub Release
                uses: softprops/action-gh-release@v2
                with:
                  files: dist/**/*
                  generate_release_notes: true
        """
    }
}
