import ArgumentParser
import Foundation

/// How a vendored native library reaches the build — both the ones swift-pwa
/// resolves itself (the llama.cpp and ONNX Runtime tiers) and the ones an app
/// declares in `pwa.json`.
///
/// Two search paths, because a vendored library has two halves and the compile
/// comes first: `native_include_dirs` puts its headers where the clang importer
/// looks, `native_library_dirs` puts its binaries where the linker looks. An
/// app that could declare only the second couldn't vendor anything with an API
/// — the build died at the first Swift module importing the C shim, long before
/// any link step (#238).
///
/// swift-pwa never writes a `-L` into a package manifest's `unsafeFlags`: that
/// poisons dependency resolution for everyone depending on the package. The
/// search path is handed to the build instead. It used to be handed over as an
/// environment variable — `LIBRARY_PATH` on Linux, `LIB` on Windows — and
/// **Swift 6.4's `swiftbuild` engine does not forward those to the link task**
/// (measured on the Android cross-compile: `ld.lld: error: unable to find
/// library -lonnxruntime` with the variable set, a clean link with the flag).
/// It fails looking like a missing dependency rather than a missing search
/// path, which is the kind of error nobody finds. A `-Xlinker` search path
/// reaches both build engines, so it is the single mechanism now — deliberately
/// one and not two, because a second, redundant one is exactly what let this
/// break go unnoticed for a release.
enum NativeLibrarySearch {
    /// `swift build` arguments putting `dirs` on the link step's library
    /// search path.
    ///
    /// Apple and Linux link through a clang driver onto `ld`/`lld`, which take
    /// `-L<dir>`. Windows links with `link.exe` / `lld-link`, which take
    /// `/LIBPATH:<dir>` and do not understand `-L` at all — an `-L` there is
    /// read as an input filename and the link fails on *that* instead.
    static func linkerArgs(for dirs: [URL], target: BuildTarget) -> [String] {
        dirs.flatMap { dir -> [String] in
            switch target {
            case .windows: ["-Xlinker", "/LIBPATH:\(dir.path)"]
            default: ["-Xlinker", "-L\(dir.path)"]
            }
        }
    }

    /// `swift build` arguments putting `dirs` on the **header** search path of
    /// every C/Objective-C compile and clang-module build the package drives.
    ///
    /// No per-target spelling: the clang importer takes `-I` on every platform
    /// this ships to, `clang-cl` included, and it is already the spelling
    /// ``WindowsBundler`` uses for the WebView2 and WIL headers.
    ///
    /// `CPATH` is not an alternative. It is what an app vendoring SQLite used
    /// through 0.10.x, and Swift 6.4's `swiftbuild` engine drops it for the same
    /// reason it drops `LIBRARY_PATH` (#219) — the compile fails as
    /// `'sqlite3.h' file not found`, which reads as a missing dependency rather
    /// than a missing search path.
    static func compilerArgs(for dirs: [URL]) -> [String] {
        dirs.flatMap { ["-Xcc", "-I\($0.path)"] }
    }

    /// Which of an app's two declared search-path lists is being resolved.
    /// The raw value is the `pwa.json` key, so a diagnostic names the line the
    /// user has to go and edit.
    enum DirKind: String {
        case library = "native_library_dirs"
        case include = "native_include_dirs"
    }

    /// The `native_library_dirs` / `native_include_dirs` an app declared for
    /// `target`, resolved against the project root and checked to exist.
    ///
    /// `<abi>` is substituted with the Android ABI being linked — the same
    /// placeholder ``OnnxRuntimeAndroidArtifact/urlTemplate`` uses, and the
    /// only one, because Android is the only target that links several
    /// architectures in a single build. That is also why a global search path
    /// can't express this: one value can carry one ABI's copy.
    ///
    /// Throws rather than skipping a directory that isn't there. A vendored
    /// library that silently doesn't reach the link step surfaces as
    /// `unable to find library -lfoo`, which names neither the manifest entry
    /// nor the path it pointed at.
    static func declaredDirs(
        manifest: PWAManifest,
        target: BuildTarget,
        projectRoot: URL,
        abi: String? = nil,
        kind: DirKind = .library
    ) throws -> [URL] {
        let declared: [String]? = switch (kind, target) {
        case (.library, .android): manifest.android?.nativeLibraryDirs
        case (.library, .linux): manifest.linux?.nativeLibraryDirs
        case (.library, .windows): manifest.windows?.nativeLibraryDirs
        case (.include, .android): manifest.android?.nativeIncludeDirs
        case (.include, .linux): manifest.linux?.nativeIncludeDirs
        case (.include, .windows): manifest.windows?.nativeIncludeDirs
        case (_, .macos), (_, .ios): nil
        }
        guard let declared, !declared.isEmpty else { return [] }

        return try declared.map { entry in
            let substituted: String
            if entry.contains("<abi>") {
                guard let abi else {
                    throw ValidationError("""
                    swift-pwa: \(target.rawValue).\(kind.rawValue) entry "\(entry)" uses <abi>, \
                    which only --target android substitutes (it is the only target that links more \
                    than one architecture per build). Name the directory outright.
                    """)
                }
                substituted = entry.replacingOccurrences(of: "<abi>", with: abi)
            } else {
                substituted = entry
            }
            let url = substituted.hasPrefix("/") || substituted.contains(":\\")
                ? URL(fileURLWithPath: substituted)
                : projectRoot.appendingPathComponent(substituted)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                let forABI = abi.map { " (for \($0))" } ?? ""
                throw ValidationError("""
                swift-pwa: \(target.rawValue).\(kind.rawValue) names "\(entry)"\(forABI), but \
                \(url.path) is not a directory. Paths are relative to the project root \
                (the directory holding pwa.json); an absolute path is used as given.
                """)
            }
            return url
        }
    }

    /// Search-path flags for a build of the app **for this machine**.
    ///
    /// `dev`, `drive` and the headless catalog dump all build and run the app
    /// on the host, whatever `--target` says, so they need the host's search
    /// paths — not the ones the bundler will pass. `extra` carries the tiers
    /// swift-pwa resolved itself, which are only ever non-empty when the
    /// target *is* the host.
    static func hostLinkerArgs(
        manifest: PWAManifest, projectRoot: URL, extra: [URL] = []
    ) throws -> [String] {
        var dirs = try extra + declaredDirs(manifest: manifest, target: .host, projectRoot: projectRoot)
        dirs += windowsPackageDirs(projectRoot: projectRoot).libDirs
        return linkerArgs(for: dirs, target: .host)
    }

    /// The WebView2 / WIL NuGet package directories, on Windows.
    ///
    /// These are a vendored dependency swift-pwa resolves for the app, in the
    /// same sense as the llama.cpp and ONNX Runtime tiers — the difference is
    /// only that they were resolved inside ``WindowsBundler`` and so reached
    /// the bundler's own `swift build` and nothing else. Empty everywhere but
    /// Windows.
    private static func windowsPackageDirs(projectRoot: URL) -> (includeDirs: [URL], libDirs: [URL]) {
        #if os(Windows)
            WindowsBundler.resolvePackagePaths(projectRoot: projectRoot, quiet: true) ?? ([], [])
        #else
            ([], [])
        #endif
    }

    /// Header search-path flags for a build of the app **for this machine**.
    ///
    /// Same reach as ``hostLinkerArgs``, and for the same reason: `dev`,
    /// `drive` and the headless catalog dump compile the app's sources, so a
    /// vendored header they can't find stops them where `build` would have
    /// worked. No `extra` — the tiers swift-pwa resolves reach the compile
    /// through their own SwiftPM targets, and there is no second consumer to
    /// generalize for.
    static func hostCompilerArgs(manifest: PWAManifest, projectRoot: URL) throws -> [String] {
        var dirs = try declaredDirs(
            manifest: manifest, target: .host, projectRoot: projectRoot, kind: .include
        )
        dirs += windowsPackageDirs(projectRoot: projectRoot).includeDirs
        return compilerArgs(for: dirs)
    }

    /// Environment additions so a *run* of the app on this host can load what
    /// it just linked against.
    ///
    /// `dev`, `drive` and the headless catalog dump run the binary straight out
    /// of `.build`, where nothing has staged the vendored libraries — the
    /// bundlers' staging only reaches the packaged artifact. Without this the
    /// build links cleanly and the run dies at load
    /// (`libsqlite3.so: cannot open shared object file`), which is the same
    /// failure an unstaged bundle would produce on a user's machine.
    ///
    /// Empty on Apple: `native_library_dirs` isn't offered there (SwiftPM's
    /// `.binaryTarget` xcframework is), and `DYLD_LIBRARY_PATH` wouldn't
    /// survive the hop through a SIP-protected `swift` anyway.
    static func hostRuntimeEnvironment(
        manifest: PWAManifest, projectRoot: URL, extra: [URL] = []
    ) throws -> [String: String] {
        let dirs = try extra + declaredDirs(manifest: manifest, target: .host, projectRoot: projectRoot)
        guard !dirs.isEmpty else { return [:] }
        #if os(Linux) || os(Windows)
            // Windows has no LD_LIBRARY_PATH — its loader searches the exe's
            // own directory, then PATH.
            #if os(Windows)
                let key = "PATH"
                let separator = ";"
            #else
                let key = "LD_LIBRARY_PATH"
                let separator = ":"
            #endif
            let paths = dirs.map(\.path)
            let existing = ProcessInfo.processInfo.environment
                .first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
            // Keyed by the spelling the environment already uses (`Path`, not
            // `PATH`) where there is one. Windows compares environment names
            // case-insensitively, and handing a child a block holding both
            // spellings is fatal rather than merely redundant: SwiftPM builds
            // its `ProcessEnvironmentKey` dictionary from it and traps with
            // `Duplicate values for key: ProcessEnvironmentKey(value: "PATH")`,
            // which names neither swift-pwa nor the manifest entry that caused
            // it. Measured on a real Windows box — every `swift-pwa build` of
            // an app declaring `windows.native_library_dirs` died here.
            //
            // Spelled out rather than built in one dictionary literal: the
            // inline form type-checked on macOS and crashed the 6.4 Windows
            // compiler outright ("failed to produce diagnostic for
            // expression").
            let resolvedKey = existing?.key ?? key
            var ordered = paths
            if let inherited = existing?.value { ordered.append(inherited) }
            return [resolvedKey: ordered.joined(separator: separator)]
        #else
            return [:]
        #endif
    }

    /// The libraries in `dir` that have to travel with the app, so it doesn't
    /// link cleanly and then die at load.
    ///
    /// Everything in the directory, deliberately. Reading the built binary's
    /// `DT_NEEDED` list instead would stage less, but it misses anything the
    /// app `dlopen`s by name, and that failure only shows up at runtime on a
    /// user's machine. Static archives aren't staged — there is nothing to
    /// load.
    static func stageableLibraries(in dir: URL, target: BuildTarget) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { name in
                switch target {
                case .windows: name.lowercased().hasSuffix(".dll")
                // `.so`, and the SONAME'd spellings beside it (`libfoo.so.1`) —
                // which is the name a NEEDED entry actually references.
                default: name.hasSuffix(".so") || name.contains(".so.")
                }
            }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }
}
