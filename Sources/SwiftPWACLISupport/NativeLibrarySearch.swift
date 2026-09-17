import ArgumentParser
import Foundation

/// How a vendored native library reaches the link step — both the ones
/// swift-pwa resolves itself (the llama.cpp and ONNX Runtime tiers) and the
/// ones an app declares in `pwa.json`.
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

    /// The `native_library_dirs` an app declared for `target`, resolved
    /// against the project root and checked to exist.
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
        abi: String? = nil
    ) throws -> [URL] {
        let declared: [String]? = switch target {
        case .android: manifest.android?.nativeLibraryDirs
        case .linux: manifest.linux?.nativeLibraryDirs
        case .windows: manifest.windows?.nativeLibraryDirs
        case .macos, .ios: nil
        }
        guard let declared, !declared.isEmpty else { return [] }

        return try declared.map { entry in
            let substituted: String
            if entry.contains("<abi>") {
                guard let abi else {
                    throw ValidationError("""
                    swift-pwa: \(target.rawValue).native_library_dirs entry "\(entry)" uses <abi>, \
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
                swift-pwa: \(target.rawValue).native_library_dirs names "\(entry)"\(forABI), but \
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
        let dirs = try extra + declaredDirs(manifest: manifest, target: .host, projectRoot: projectRoot)
        return linkerArgs(for: dirs, target: .host)
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
                .first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            return [key: (existing.map { paths + [$0] } ?? paths).joined(separator: separator)]
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
