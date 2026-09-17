import Foundation

/// Locates the host-side Android toolchain — SDK, NDK, JDK — that a
/// cross-compile and a Gradle assemble need: from the environment first, then
/// from each platform's standard install locations.
///
/// Discovery rather than "export these three variables" because every gap here
/// otherwise surfaces as an error from a *child* process, far from its cause:
/// Gradle's `SDK location not found`, macOS's `Unable to locate a Java
/// Runtime` (a `/usr/bin/java` **stub** is on PATH even with no JDK installed,
/// so presence proves nothing), or — worst, because it doesn't fail at all —
/// Xcode's Mach-O `strip` rejecting `--strip-unneeded` and the APK silently
/// shipping ~130 MB of unstripped `.so`. The CLI already knows it's building
/// for Android; it can find these itself and say something actionable when it
/// can't.
///
/// The selection logic is pure over injected `Probes` so it's unit-testable
/// against a synthetic filesystem — candidate lists cover every host, and
/// validation filters the ones that don't exist.
enum AndroidToolchain {
    /// A located toolchain component.
    struct Found: Equatable {
        let path: String
        /// The environment variable it came from, or `nil` when it was found
        /// at a standard install location.
        let envVar: String?

        /// For diagnostics: `$ANDROID_HOME (/path)` or the bare path.
        var origin: String {
            envVar.map { "$\($0) (\(path))" } ?? path
        }
    }

    /// How Gradle should get its JDK.
    enum JavaResolution: Equatable {
        /// `$JAVA_HOME`, or a working `java` on PATH — nothing to override.
        case ambient
        /// Nothing usable is ambient, but a JDK is installed here; point
        /// Gradle at it with `JAVA_HOME`.
        case discovered(Found)
        /// No JDK on the machine.
        case missing
    }

    // MARK: - Probes

    /// Filesystem reads the selection logic needs, injected so tests can hand
    /// it a synthetic layout instead of the real machine.
    struct Probes {
        var isDirectory: @Sendable (String) -> Bool
        var isExecutable: @Sendable (String) -> Bool
        var contentsOfDirectory: @Sendable (String) -> [String]
        /// Contents of a JDK's `release` file (every JDK 9+ ships one), or nil.
        var releaseFile: @Sendable (String) -> String?

        static let host = Probes(
            isDirectory: { path in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                return exists && isDir.boolValue
            },
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            contentsOfDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            releaseFile: { try? String(contentsOfFile: "\($0)/release", encoding: .utf8) }
        )
    }

    // MARK: - SDK

    /// The Android SDK root (Gradle's `sdk.dir`). Needed by AGP, not by the
    /// Swift cross-compile — the Swift Android SDK carries its own sysroot.
    static func sdk(
        env: [String: String] = ProcessInfo.processInfo.environment,
        probes: Probes = .host
    ) -> Found? {
        firstValid(sdkCandidates(env: env), isValid: { isSDK($0, probes: probes) })
    }

    /// Ordered SDK candidates: the two conventional env vars, then the
    /// per-platform default install locations (macOS, Linux, Windows, and the
    /// GitHub-hosted-runner path so CI works unconfigured).
    static func sdkCandidates(env: [String: String]) -> [Found] {
        var candidates = envCandidates(env, ["ANDROID_HOME", "ANDROID_SDK_ROOT"])
        let home = env["HOME"] ?? NSHomeDirectory()
        candidates.append(Found(path: "\(home)/Library/Android/sdk", envVar: nil))
        candidates.append(Found(path: "\(home)/Android/Sdk", envVar: nil))
        if let localAppData = env["LOCALAPPDATA"] {
            candidates.append(Found(path: "\(localAppData)/Android/Sdk", envVar: nil))
        }
        candidates.append(Found(path: "/usr/local/lib/android/sdk", envVar: nil))
        return candidates
    }

    /// An SDK root has `platform-tools` (adb) or at least one installed
    /// `platforms/android-NN`. Checking both means a platform-tools-only
    /// install (common when Gradle downloads the rest) still resolves.
    static func isSDK(_ path: String, probes: Probes = .host) -> Bool {
        probes.isDirectory("\(path)/platform-tools") || probes.isDirectory("\(path)/platforms")
    }

    // MARK: - NDK

    /// The Android NDK root. Used for `llvm-strip` / `llvm-readelf` (the only
    /// ELF-capable binutils on a macOS host) and reported to Gradle as
    /// `ndk.dir`.
    ///
    /// Pass the already-resolved `sdk` so an SDK-manager NDK
    /// (`<sdk>/ndk/<version>`) is found without re-resolving the SDK.
    static func ndk(
        env: [String: String] = ProcessInfo.processInfo.environment,
        sdk sdkPath: String? = nil,
        probes: Probes = .host
    ) -> Found? {
        firstValid(
            ndkCandidates(env: env, sdk: sdkPath, probes: probes),
            isValid: { isNDK($0, probes: probes) }
        )
    }

    /// Ordered NDK candidates: the env vars, then the SDK manager's
    /// `<sdk>/ndk/<version>` (newest version first) and the legacy
    /// `<sdk>/ndk-bundle`.
    static func ndkCandidates(env: [String: String], sdk sdkPath: String?, probes: Probes = .host) -> [Found] {
        var candidates = envCandidates(env, ["ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "NDK_HOME"])
        let root = sdkPath ?? sdk(env: env, probes: probes)?.path
        guard let root else { return candidates }
        let versions = probes.contentsOfDirectory("\(root)/ndk")
            .sorted { compareVersions($0, $1) == .orderedDescending }
        candidates += versions.map { Found(path: "\(root)/ndk/\($0)", envVar: nil) }
        candidates.append(Found(path: "\(root)/ndk-bundle", envVar: nil))
        return candidates
    }

    static func isNDK(_ path: String, probes: Probes = .host) -> Bool {
        probes.isDirectory("\(path)/toolchains/llvm/prebuilt")
    }

    /// Absolute path to an NDK-prebuilt LLVM binutil (`llvm-strip`,
    /// `llvm-readelf`, …), across the four prebuilt host flavours.
    static func ndkTool(_ name: String, ndk: String, probes: Probes = .host) -> String? {
        ["darwin-x86_64", "darwin-arm64", "linux-x86_64", "windows-x86_64"]
            .map { "\(ndk)/toolchains/llvm/prebuilt/\($0)/bin/\(name)" }
            .first { probes.isExecutable($0) }
    }

    // MARK: - JDK

    /// Where Gradle's JDK comes from. Async because the only honest test of a
    /// `java` on PATH is running it — see `ambientJavaRuns`.
    static func resolveJava(
        env: [String: String] = ProcessInfo.processInfo.environment,
        probes: Probes = .host
    ) async -> JavaResolution {
        if let home = env["JAVA_HOME"], isJDK(home, probes: probes) { return .ambient }
        if await ambientJavaRuns() { return .ambient }
        if let found = jdk(env: env, probes: probes) { return .discovered(found) }
        return .missing
    }

    /// Whether a `java` on PATH actually runs. macOS ships a `/usr/bin/java`
    /// **stub** that exists and is executable but exits non-zero with "Unable
    /// to locate a Java Runtime" when no JDK is installed — so a PATH lookup
    /// (what `doctor` used to do) reports a JDK that isn't there, and the
    /// failure lands mid-Gradle instead. Executing it is the only real check.
    static func ambientJavaRuns() async -> Bool {
        await (try? Shell.capture("java", ["-version"], timeout: 15, discardStderr: true)) != nil
    }

    /// The best installed JDK, ignoring what's ambient. Ranked by
    /// `jdkPreferenceRank` rather than taken first-found, because the standard
    /// locations hold several JDKs on a typical machine and only some of them
    /// can run the generated project's Gradle.
    static func jdk(
        env: [String: String] = ProcessInfo.processInfo.environment,
        probes: Probes = .host
    ) -> Found? {
        if let home = env["JAVA_HOME"], isJDK(home, probes: probes) {
            return Found(path: home, envVar: "JAVA_HOME")
        }
        let usable = jdkCandidates(env: env, probes: probes)
            .filter { isJDK($0.path, probes: probes) }
            .map { (found: $0, rank: jdkPreferenceRank(major: jdkMajorVersion($0.path, probes: probes))) }
            .filter { $0.rank != nil }
        // Stable pick: rank first, then path, so two equally-ranked JDKs don't
        // alternate with directory-enumeration order between runs.
        return usable.min {
            ($0.rank ?? .max, $0.found.path) < ($1.rank ?? .max, $1.found.path)
        }?.found
    }

    /// Ordered JDK candidates across hosts: the per-platform system stores,
    /// Homebrew's keg-only `openjdk*` (never symlinked into
    /// `/Library/Java/JavaVirtualMachines`, so `/usr/libexec/java_home` can't
    /// see it — a very common macOS state), and Android Studio's bundled JBR.
    static func jdkCandidates(env: [String: String], probes: Probes = .host) -> [Found] {
        var candidates: [Found] = []
        if let home = env["JAVA_HOME"] { candidates.append(Found(path: home, envVar: "JAVA_HOME")) }

        // macOS system store: /Library/Java/JavaVirtualMachines/<jdk>/Contents/Home
        for jdk in probes.contentsOfDirectory("/Library/Java/JavaVirtualMachines") {
            candidates.append(Found(path: "/Library/Java/JavaVirtualMachines/\(jdk)/Contents/Home", envVar: nil))
        }
        // Homebrew keg-only openjdk / openjdk@17 / openjdk@21 …
        for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for formula in probes.contentsOfDirectory(prefix) where formula.hasPrefix("openjdk") {
                candidates.append(
                    Found(path: "\(prefix)/\(formula)/libexec/openjdk.jdk/Contents/Home", envVar: nil)
                )
            }
        }
        // Linux system store.
        for jdk in probes.contentsOfDirectory("/usr/lib/jvm") {
            candidates.append(Found(path: "/usr/lib/jvm/\(jdk)", envVar: nil))
        }
        // Windows.
        for programFiles in [env["ProgramFiles"], env["ProgramW6432"]].compactMap(\.self) {
            for vendor in ["Java", "Eclipse Adoptium", "Microsoft"] {
                for jdk in probes.contentsOfDirectory("\(programFiles)/\(vendor)") {
                    candidates.append(Found(path: "\(programFiles)/\(vendor)/\(jdk)", envVar: nil))
                }
            }
        }
        // Android Studio's bundled JetBrains Runtime — a JDK the developer
        // already has if they installed the SDK the normal way.
        candidates.append(Found(path: "/Applications/Android Studio.app/Contents/jbr/Contents/Home", envVar: nil))
        candidates.append(Found(path: "/opt/android-studio/jbr", envVar: nil))
        if let localAppData = env["LOCALAPPDATA"] {
            candidates.append(Found(path: "\(localAppData)/Programs/Android Studio/jbr", envVar: nil))
        }
        return candidates
    }

    /// A JDK home has a runnable `bin/java` **and** a `release` file. The
    /// second half matters: it's what distinguishes a real JDK from a
    /// stub-bearing prefix like `/usr` on macOS (`/usr/bin/java` exists,
    /// `/usr/release` doesn't).
    static func isJDK(_ path: String, probes: Probes = .host) -> Bool {
        let java = probes.isExecutable("\(path)/bin/java") || probes.isExecutable("\(path)/bin/java.exe")
        return java && probes.releaseFile(path) != nil
    }

    /// Major version from a JDK's `release` file (`JAVA_VERSION="17.0.19"`).
    static func jdkMajorVersion(_ path: String, probes: Probes = .host) -> Int? {
        guard let release = probes.releaseFile(path) else { return nil }
        return jdkMajorVersion(fromRelease: release)
    }

    /// Pure parse of a `release` file's `JAVA_VERSION` → major version.
    /// Handles both the modern `"17.0.19"` and legacy `"1.8.0_402"` shapes.
    static func jdkMajorVersion(fromRelease release: String) -> Int? {
        for line in release.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("JAVA_VERSION=") else { continue }
            let value = line.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let parts = value.split(separator: ".")
            guard let first = parts.first.flatMap({ Int($0) }) else { return nil }
            // 1.8.0_402 → 8; anything else is already the major.
            if first == 1 { return parts.dropFirst().first.flatMap { Int($0) } }
            return first
        }
        return nil
    }

    /// Sort key for a JDK (lower is better), or `nil` for one that can't run
    /// the build at all.
    ///
    /// The generated project pins AGP 8.5 / Gradle 8.10 and compiles to Java
    /// 17. Gradle 8.10 runs on JDK 17–22 and AGP 8.5 requires 17+, so: prefer
    /// exactly 17, then the newest in-range JDK, then — only as a last resort,
    /// oldest first — one above the range (Gradle may still accept it, and a
    /// real Gradle error beats us claiming no JDK exists). Below 17 is
    /// excluded: picking one guarantees a failure with a confusing message.
    static func jdkPreferenceRank(major: Int?) -> Int? {
        guard let major else { return 3000 } // unversioned: usable, ranked last
        if major == 17 { return 0 }
        if major < 17 { return nil }
        if major <= 22 { return 1000 - major }
        return 2000 + major
    }

    // MARK: - Swift release matching

    /// An installed Swift Android SDK bundle: its directory name (minus
    /// `.artifactbundle`) and the Swift release it was built with.
    ///
    /// `release` is `nil` when the name carries no version this understands.
    /// That is worth reporting rather than folding into "no SDK": it is the
    /// state where a cross-build silently runs under whatever compiler is
    /// ambient and fails on module version, far from the cause.
    struct InstalledAndroidSDK: Equatable {
        let bundle: String
        let release: String?
    }

    /// Candidate SwiftPM swift-sdks roots, most-likely first. The root varies
    /// by host *and* by SwiftPM version / install method, so every caller
    /// probes the list rather than assuming one — getting it wrong silently
    /// skips runtime-stdlib bundling, and the APK then assembles fine and
    /// crashes at `System.loadLibrary` on-device.
    static func swiftSDKRoots(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let home = env["HOME"] ?? NSHomeDirectory()
        var roots: [String] = []
        #if os(macOS)
            roots.append("\(home)/Library/org.swift.swiftpm/swift-sdks")
        #endif
        // Legacy data dir — what swiftly-managed toolchains use today.
        roots.append("\(home)/.swiftpm/swift-sdks")
        // XDG location (newer SwiftPM): $XDG_DATA_HOME ?? ~/.local/share.
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            roots.append("\(xdg)/swiftpm/swift-sdks")
        }
        roots.append("\(home)/.local/share/swiftpm/swift-sdks")
        if let appData = env["APPDATA"], !appData.isEmpty {
            roots.append("\(appData)/org.swift.swiftpm/swift-sdks")
        }
        return roots
    }

    /// The installed Swift Android SDK bundle, if there is one. Sorted
    /// descending so a machine carrying two SDK generations reports the newer
    /// one — the one a fresh `swift sdk install` just put there.
    static func installedAndroidSDK(
        env: [String: String] = ProcessInfo.processInfo.environment,
        probes: Probes = .host
    ) -> InstalledAndroidSDK? {
        for root in swiftSDKRoots(env: env) {
            let names = probes.contentsOfDirectory(root)
                .filter { $0.lowercased().contains("android") }
                .sorted(by: >)
            guard let name = names.first else { continue }
            let bundle = name.hasSuffix(".artifactbundle")
                ? String(name.dropLast(".artifactbundle".count))
                : name
            return InstalledAndroidSDK(bundle: bundle, release: swiftRelease(inSDKBundleName: bundle))
        }
        return nil
    }

    /// The `major.minor` Swift release a Swift Android SDK bundle name
    /// declares. Two spellings, because the bundle was renamed: through 6.2 it
    /// was `swift-6.2-RELEASE-android-0.1`, from 6.4 it is
    /// `swift-6.4.0-RELEASE_android`. Understanding only the old spelling
    /// meant no toolchain was selected at all, silently, and the cross-build
    /// ran under Xcode's Swift and failed on module version.
    ///
    /// The `android` requirement is what keeps this from claiming a plain
    /// `swift-6.2-RELEASE.xctoolchain` is an Android SDK.
    static func swiftRelease(inSDKBundleName name: String) -> String? {
        guard name.lowercased().contains("android"),
              let range = name.range(of: #"^swift-[0-9]+\.[0-9]+"#, options: .regularExpression)
        else { return nil }
        return String(name[range].dropFirst("swift-".count))
    }

    /// Installed release `.xctoolchain` **names** that can compile against
    /// Swift `release` (`"6.4"`), best match first: the exact
    /// `swift-<release>-RELEASE.xctoolchain`, then any `swift-<release>.…`
    /// bundle (a patch-versioned or same-line snapshot toolchain).
    ///
    /// Apple-shaped by nature — `.xctoolchain` and `TOOLCHAINS` are Xcode
    /// concepts. Elsewhere the equivalent match is made through swiftly; see
    /// `AndroidBundler.androidBuildTool`.
    static func releaseToolchainNames(
        matching release: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        probes: Probes = .host
    ) -> [String] {
        let home = env["HOME"] ?? NSHomeDirectory()
        let exact = "swift-\(release)-RELEASE.xctoolchain"
        return probes.contentsOfDirectory("\(home)/Library/Developer/Toolchains")
            .filter {
                $0.hasSuffix(".xctoolchain")
                    && ($0.hasPrefix("swift-\(release)-RELEASE") || $0.hasPrefix("swift-\(release)."))
            }
            // Rank exact=0/other=1 so the comparator is a real strict-weak
            // ordering — a bare `$0 == exact` predicate isn't, and yields
            // undefined results once several candidates exist.
            .sorted { ($0 == exact ? 0 : 1, $0) < ($1 == exact ? 0 : 1, $1) }
    }

    // MARK: - Gradle environment

    /// Env overrides for a `gradlew` invocation. Only the pieces the ambient
    /// environment is actually missing — an inherited `ANDROID_HOME` or
    /// working `JAVA_HOME` is left exactly as the user set it.
    static func gradleEnvironment(java: JavaResolution, sdk: Found?) -> [String: String] {
        var overrides: [String: String] = [:]
        if case let .discovered(jdk) = java { overrides["JAVA_HOME"] = jdk.path }
        if let sdk, sdk.envVar == nil {
            overrides["ANDROID_HOME"] = sdk.path
            overrides["ANDROID_SDK_ROOT"] = sdk.path
        }
        return overrides
    }

    /// `local.properties` for the generated Gradle project — the canonical
    /// place Gradle reads the SDK location from, so the staged project is also
    /// buildable by hand and openable in Android Studio, not just through
    /// `swift-pwa deploy`.
    ///
    /// `sdk.dir` only, deliberately: the project has no C/C++ sources (the
    /// Swift `.so` files are cross-compiled and staged into `jniLibs/`
    /// already stripped), so AGP never needs an NDK — and an `ndk.dir` it
    /// doesn't need still gets version-matched against its default
    /// `android.ndkVersion`, printing a CXX1104 mismatch on every module task.
    static func localProperties(sdk: Found?) -> String? {
        guard let sdk else { return nil }
        return """
        # Generated by swift-pwa. Machine-local paths — not source, don't commit.
        sdk.dir=\(escapeForProperties(sdk.path))

        """
    }

    /// `.properties` is ISO-8859-1 with `\` as the escape character, so a
    /// Windows path (`C:\Users\…`) has to be escaped or Gradle reads
    /// `C:Users…`. Colons and `=` are only special in the key half, but
    /// escaping them is harmless and matches what Android Studio writes.
    static func escapeForProperties(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
    }

    // MARK: - Helpers

    private static func envCandidates(_ env: [String: String], _ keys: [String]) -> [Found] {
        keys.compactMap { key in
            guard let value = env[key], !value.isEmpty else { return nil }
            return Found(path: value, envVar: key)
        }
    }

    private static func firstValid(_ candidates: [Found], isValid: (String) -> Bool) -> Found? {
        candidates.first { isValid($0.path) }
    }

    /// Compare dotted NDK version dirs (`27.1.12297006` vs `26.3.11579264`)
    /// numerically — a lexicographic sort would rank `9.x` above `27.x`.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
