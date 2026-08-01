import ArgumentParser
import Foundation
import SwiftPWACore

/// Builds an Android Gradle project that wraps the user's
/// Swift-compiled `.so` plus their web bundle.
///
/// The output is *always* a Gradle project, never a standalone APK
/// directly: `aapt2` / `d8` invocation is what Android Studio /
/// `gradlew` are good at, and re-implementing that pipeline in the
/// CLI would be a maintenance burden disproportionate to the value.
/// `--build-apk` (a future v0.5.x flag) will additionally invoke
/// `./gradlew assembleDebug` once that flow is wired up; for v0.5
/// kickoff we generate the project and stop.
///
/// **Important caveat for v0.5 kickoff:** the Swift-on-Android
/// toolchain is invoked through whatever `swift build --triple
/// aarch64-unknown-linux-android24` is configured to do on the
/// host. The CLI does *not* embed an Android NDK or download the
/// Swift Android SDK; the user is expected to have one installed
/// (Swift 6.1+ ships official Android target support, but the
/// standalone SDK distribution still needs manual setup — see
/// `docs/android-setup.md`). When `swift build --triple <android>`
/// fails or is unavailable, this bundler emits the Gradle scaffold
/// minus the `.so` files and prints a clear diagnostic, so the
/// project layout can still be inspected and the missing piece
/// fixed in isolation.
struct AndroidBundler {
    let manifest: PWAManifest
    let projectRoot: URL
    let outputDir: URL
    let abis: [String]
    /// If true, runs `swift build --triple <abi>` for each requested
    /// ABI and stages the resulting `.so`. When false (the default
    /// for now), we skip the cross-compile and warn — useful for
    /// generating just the Gradle scaffold on a host that doesn't
    /// have the Swift Android SDK installed.
    let crossCompile: Bool
    /// If true, prune the bundled Swift runtime stdlib to only what
    /// the app's `.so` actually requires via a transitive `DT_NEEDED`
    /// walk (`readelf -d`). Drops the unstripped wholesale set from
    /// 124 MB to 113 MB on `Examples/HelloPWA` (10 stdlib `.so` files
    /// the binary doesn't actually pull in — `_Differentiation`,
    /// `_StringProcessing`, `RegexBuilder`, `Distributed`,
    /// `FoundationXML`, `Testing`, `XCTest`, `_Volatile`,
    /// `Observation`, `_SwiftOnoneSupport`). After stripping is also
    /// applied (which happens unconditionally in this bundler), the
    /// effective APK delta of pruning is ~5 MB on top of the ~50 MB
    /// strip already saves. See `stageSwiftRuntime` /
    /// `prunedRuntimeSet` for the implementation.
    let pruneRuntime: Bool
    /// CLI override for `pwa.json`'s `android.signing.keystore`. Path
    /// to a `.jks` / `.keystore` / `.p12`; relative paths resolve
    /// against `projectRoot`. When set with no `pwa.json` signing
    /// section present, an alias is required via `keyAliasOverride`
    /// (the bundler errors out otherwise).
    let signKeystoreOverride: String?
    /// CLI override for `pwa.json`'s `android.signing.key_alias`.
    let keyAliasOverride: String?

    func build() async throws -> URL {
        let project = outputDir.appendingPathComponent("\(manifest.name)-android")
        if FileManager.default.fileExists(atPath: project.path) {
            try FileManager.default.removeItem(at: project)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let pkg = androidPackageId()
        // Catch a stale JNI entry point (package_id changed after `init`)
        // before producing an APK that would UnsatisfiedLinkError at launch.
        if let drift = AndroidEntryDrift.detect(projectRoot: projectRoot, packageId: pkg) {
            print("warning: \(AndroidEntryDrift.message(for: drift, packageId: pkg))")
        }
        // SwiftPM product name → `lib<name>.so`. Resolved from the
        // package rather than guessed from the display `name`.
        let soBase = await ExecutableNameResolver.resolve(projectRoot: projectRoot, manifest: manifest)
        let label = manifest.name
        let versionName = manifest.version
        let versionCode = manifest.android?.versionCode ?? 1
        let minSdk = manifest.android?.minSdk ?? 28
        let targetSdk = manifest.android?.targetSdk ?? 34
        // `ai.gemini_nano: true` → add the ML Kit GenAI Gradle dep + splice the
        // `ai.gemini.*` Kotlin dispatch the `GeminiNanoBackend` RPCs into.
        let geminiNanoEnabled = manifest.ai?.geminiNano == true
        // `window.background_color` → paint the launch window, system bars, and
        // WebView surface to match (no white flash before first paint). Parsed
        // here so an invalid hex degrades to the stock theme rather than
        // emitting a broken resource. Mirrors the other backends, which all
        // honour the same field.
        let windowBackground = manifest.window.backgroundColor
            .flatMap(AndroidTemplates.WindowBackground.init)

        // Project-level files.
        let settings = AndroidTemplates.settingsGradleKts(label: label)
        try settings.write(
            to: project.appendingPathComponent("settings.gradle.kts"),
            atomically: true, encoding: .utf8
        )
        try AndroidTemplates.rootBuildGradleKts(enableGeminiNano: geminiNanoEnabled).write(
            to: project.appendingPathComponent("build.gradle.kts"),
            atomically: true, encoding: .utf8
        )
        try AndroidTemplates.gradleProperties.write(
            to: project.appendingPathComponent("gradle.properties"),
            atomically: true, encoding: .utf8
        )
        // `local.properties` is where Gradle reads the SDK (and NDK) location
        // from. Writing the discovered paths here means the staged project
        // assembles by hand (`cd <out> && ./gradlew assembleDebug`) and opens
        // in Android Studio on a machine that never exported ANDROID_HOME —
        // otherwise the first thing the developer meets is AGP's "SDK location
        // not found" pointing at a file we could have written.
        if let properties = AndroidToolchain.localProperties(sdk: AndroidToolchain.sdk()) {
            try properties.write(
                to: project.appendingPathComponent("local.properties"),
                atomically: true, encoding: .utf8
            )
        }

        // App module.
        let app = project.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let signing = try resolveSigning()
        try AndroidTemplates.appBuildGradleKts(
            packageId: pkg,
            versionCode: versionCode,
            versionName: versionName,
            minSdk: minSdk,
            targetSdk: targetSdk,
            abis: abis,
            soBaseName: soBase,
            signing: signing,
            enableGeminiNano: geminiNanoEnabled
        ).write(
            to: app.appendingPathComponent("build.gradle.kts"),
            atomically: true, encoding: .utf8
        )
        if let signing {
            print(
                "configured release signing: keystore \(signing.keystoreAbsolutePath) (alias: \(signing.keyAlias)). Set SWIFT_PWA_ANDROID_STORE_PASSWORD and SWIFT_PWA_ANDROID_KEY_PASSWORD before `./gradlew assembleRelease`."
            )
        }

        // src/main layout.
        let main = app.appendingPathComponent("src/main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)

        // Launcher icon: drop the source PNG into res/mipmap/ic_launcher.png
        // and reference it from the manifest. aapt/Gradle scale it per
        // density at build time, so a single PNG is enough — no pre-resize.
        let iconOutcome = try stageLauncherIcon(into: main)
        IconOutcome.report(iconOutcome)
        let iconStaged = if case .bundled = iconOutcome { true } else { false }

        // res/xml/network_security_config.xml — the scoped cleartext allow-list
        // for `android.network.cleartext_domains` (e.g. a LAN ComfyUI on plain
        // http). Cleartext stays off globally; only the listed hosts are
        // permitted. Written (and referenced from the manifest) only when
        // configured — the manifest is byte-for-byte unchanged otherwise.
        let networkSecurityConfig = (manifest.android?.network?.cleartextDomains)
            .flatMap { AndroidTemplates.networkSecurityConfigXml(domains: $0) }
        if let networkSecurityConfig {
            let xmlDir = main.appendingPathComponent("res/xml")
            try FileManager.default.createDirectory(at: xmlDir, withIntermediateDirectories: true)
            try networkSecurityConfig.write(
                to: xmlDir.appendingPathComponent("network_security_config.xml"),
                atomically: true, encoding: .utf8
            )
        }

        try AndroidTemplates.androidManifestXml(
            packageId: pkg, label: label, hasIcon: iconStaged, customTheme: windowBackground != nil,
            documentTypes: manifest.android?.documentTypes ?? [],
            networkConfigStaged: networkSecurityConfig != nil
        ).write(
            to: main.appendingPathComponent("AndroidManifest.xml"),
            atomically: true, encoding: .utf8
        )

        // res/values{,-night}/swift_pwa_theme.xml — the `Theme.SwiftPWA` the
        // manifest points at when `window.background_color` is set. Written as a
        // DayNight pair: the light mode under `res/values/`, the dark mode under
        // `res/values-night/`, so Android resolves the right window colour +
        // system-bar glyph luminance per mode (and the WebView tracks
        // `prefers-color-scheme`). Only written when a colour is configured (the
        // manifest references the stock theme otherwise). A single configured
        // colour writes identical light/dark files — harmless, and keeps one
        // code path.
        if let windowBackground {
            for (dir, mode) in [("res/values", windowBackground.light), ("res/values-night", windowBackground.dark)] {
                let values = main.appendingPathComponent(dir)
                try FileManager.default.createDirectory(at: values, withIntermediateDirectories: true)
                try AndroidTemplates.swiftPWAThemeXml(mode).write(
                    to: values.appendingPathComponent("swift_pwa_theme.xml"),
                    atomically: true, encoding: .utf8
                )
            }
        }

        // Kotlin sources go under `java/<package-as-path>/...`
        let kotlinDir = main.appendingPathComponent("java/" + pkg.replacingOccurrences(of: ".", with: "/"))
        try FileManager.default.createDirectory(at: kotlinDir, withIntermediateDirectories: true)
        try AndroidTemplates.mainActivityKt(
            packageId: pkg, soBaseName: soBase, serveMounts: manifest.build?.serve ?? [],
            background: windowBackground
        ).write(
            to: kotlinDir.appendingPathComponent("MainActivity.kt"),
            atomically: true, encoding: .utf8
        )
        // The bridge class lives under a stable package
        // (`dev.swiftpwa.runtime`) because the JNI shim's exported
        // symbols are mangled with that name; user code shouldn't
        // shadow or rewrap it.
        let runtimeDir = main.appendingPathComponent("java/dev/swiftpwa/runtime")
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try AndroidTemplates.swiftPWABridgeKt(
            spaFallback: manifest.web.spaFallback ?? false,
            entry: manifest.web.entry
        ).write(
            to: runtimeDir.appendingPathComponent("SwiftPWABridge.kt"),
            atomically: true, encoding: .utf8
        )
        try AndroidTemplates.swiftPWASystemPluginsKt(enableGeminiNano: geminiNanoEnabled).write(
            to: runtimeDir.appendingPathComponent("SwiftPWASystemPlugins.kt"),
            atomically: true, encoding: .utf8
        )

        // Web bundle: copy <project>/<web.directory> into assets/web/.
        let webSrc = projectRoot.appendingPathComponent(manifest.web.directory)
        let assets = main.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: webSrc.path) {
            let webDst = assets.appendingPathComponent("web")
            try FileManager.default.copyItem(at: webSrc, to: webDst)
        } else {
            print("note: web bundle directory '\(manifest.web.directory)' missing; assets/web/ will be empty")
        }

        // Stage bridge.js alongside the assets so the Kotlin host can inject
        // it on page-start. The text comes from `BridgeJSData` — bridge.js
        // base64-embedded into this CLI (generated by
        // Scripts/regenerate-bridge-js.sh from SwiftPWACore/Resources/bridge.js).
        // We must NOT read it from `SwiftPWACore.BridgeScript.source()`
        // (`Bundle.module`) here: a PREBUILT single-file `swift-pwa` binary has
        // no co-located `SwiftPWACore.bundle`, so that traps with "could not
        // load resource bundle …" — which broke `build --target android` from
        // the prebuilt CLI (the documented install path). Embedding is the same
        // fix the Gradle wrapper uses (`GradleWrapperData`). The runtime
        // backends still read the canonical copy from Core's bundle directly.
        let bridgeJsDst = assets.appendingPathComponent("swift_pwa/bridge.js")
        try FileManager.default.createDirectory(
            at: bridgeJsDst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try BridgeJSData.source.write(to: bridgeJsDst, atomically: true, encoding: .utf8)

        // Gradle wrapper (gradlew + gradlew.bat + gradle/wrapper/*).
        // Vendored as a SwiftPWACLISupport resource so the generated
        // project is offline-complete: `cd <out> && ./gradlew
        // assembleDebug` works without a system Gradle install.
        try stageGradleWrapper(into: project)

        // jniLibs: produce one .so per requested ABI. Skipped (with
        // a warning) when --no-cross-compile or when the toolchain
        // doesn't produce one — the project still lays out cleanly
        // so the developer can inspect / fix in isolation.
        if crossCompile {
            try await stageJniLibs(into: app, soBaseName: soBase)
        } else {
            print(
                "note: --no-cross-compile in effect; jniLibs/ will be empty until you run `swift build --triple <android>` and copy the .so files manually"
            )
        }

        return project
    }

    /// Write the vendored Gradle wrapper into the generated project from
    /// data **embedded in the binary** (`GradleWrapperData`, generated by
    /// `Scripts/regenerate-gradle-wrapper.sh` from `Vendor/gradle-wrapper/`):
    ///   - `gradlew` (Unix launcher — staged 0755)
    ///   - `gradlew.bat` (Windows launcher)
    ///   - `gradle/wrapper/gradle-wrapper.jar` (bootstrap JAR, pinned Gradle version)
    ///   - `gradle/wrapper/gradle-wrapper.properties`
    ///
    /// Embedding (rather than shipping a SwiftPM resource bundle) means a
    /// prebuilt single-file `swift-pwa` binary stages `./gradlew` too — and
    /// `SwiftPWACLISupport` carries no resources, so the `Bundle.module`
    /// trap that bit prebuilt binaries can't recur.
    private func stageGradleWrapper(into project: URL) throws {
        let fm = FileManager.default
        let wrapperDir = project.appendingPathComponent("gradle/wrapper")
        try fm.createDirectory(at: wrapperDir, withIntermediateDirectories: true)

        let gradlew = project.appendingPathComponent("gradlew")
        try GradleWrapperData.gradlew.write(to: gradlew)
        try GradleWrapperData.gradlewBat.write(to: project.appendingPathComponent("gradlew.bat"))
        try GradleWrapperData.gradleWrapperJar.write(to: wrapperDir.appendingPathComponent("gradle-wrapper.jar"))
        try GradleWrapperData.gradleWrapperProperties
            .write(to: wrapperDir.appendingPathComponent("gradle-wrapper.properties"))

        // `gradlew` must be executable; we wrote raw bytes, so set the bits.
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: gradlew.path
        )
    }

    // MARK: - Helpers

    private func androidPackageId() -> String {
        AndroidEntryDrift.resolvePackageId(manifest)
    }

    /// `lib<name>.so` is what Android's loader expects under
    /// `jniLibs/<abi>/`. SwiftPM's executable target on Android produces
    /// `lib<TargetName>.so` once the user's package is configured to
    /// build a shared object (see `docs/android-setup.md`); `soBaseName`
    /// is that `<TargetName>`, resolved by `ExecutableNameResolver`.
    /// Copy the manifest's PNG icon to `res/mipmap/ic_launcher.png`.
    /// Returns whether an icon was staged (drives the manifest's
    /// `android:icon` attribute). Best-effort: a missing or non-PNG icon
    /// just yields the platform-default launcher icon, same as before.
    private func stageLauncherIcon(into main: URL) throws -> IconOutcome {
        guard let icon = manifest.icon else { return .noneSet }
        let src = projectRoot.appendingPathComponent(icon)
        guard src.pathExtension.lowercased() == "png" else {
            return .notPNG(source: icon, placeholder: false)
        }
        guard FileManager.default.fileExists(atPath: src.path) else {
            return .notFound(source: icon, placeholder: false)
        }
        let mipmap = main.appendingPathComponent("res/mipmap")
        try FileManager.default.createDirectory(at: mipmap, withIntermediateDirectories: true)
        let dst = mipmap.appendingPathComponent("ic_launcher.png")
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
        return .bundled(source: icon, detail: nil)
    }

    private func stageJniLibs(into appModule: URL, soBaseName: String) async throws {
        let jniLibs = appModule.appendingPathComponent("src/main/jniLibs")
        try FileManager.default.createDirectory(at: jniLibs, withIntermediateDirectories: true)

        // Preflight: is a Swift Android SDK installed? Without one,
        // `swift build --triple aarch64-unknown-linux-android24`
        // happily falls back to the host (macOS/Linux) clang +
        // sysroot headers and emits a wall of "architecture not
        // supported" / "unknown type name '__darwin_size_t'" errors
        // out of swift-corelibs and swift-crypto's C sources. The
        // failure is real but the diagnostic is unintelligible —
        // looks like a tool bug rather than a missing prerequisite.
        // Catch it up front so the user sees one clean line.
        guard let sdk = await detectAndroidSwiftSDK() else {
            print("""

            swift-pwa: --cross-compile-android requires a Swift Android SDK to be installed
            (none found via `swift sdk list`). Install one — typically:

                swift sdk install <swift-android-sdk artifactbundle URL>

            See https://github.com/swift-android-sdk/swift-android-sdk for the current
            distribution + checksum. Re-run this command once `swift sdk list` shows an
            entry containing 'android'.

            For now, the Gradle scaffold has been emitted without lib*.so files; you can
            either drop them in by hand under app/src/main/jniLibs/<abi>/ or re-run
            after installing the Swift Android SDK.

            """)
            return
        }

        // The Swift Android SDK keys its target resources by API-suffixed
        // triples (`aarch64-unknown-linux-android28`, etc.) in
        // `swift-sdk.json`'s `targetTriples` map. The form that resolves
        // those resources correctly is `--swift-sdk <triple>` — SwiftPM
        // looks up the triple in every installed bundle's targetTriples
        // and selects the matching `swiftResourcesPath`. The combo
        // `--swift-sdk <bundle-id> --triple <triple>` bypasses that
        // mapping and falls back to the bundle's first arch-suffixed
        // resource directory (e.g. `swift-x86_64/`), which then can't
        // satisfy `import Foundation` for an aarch64 build. So we pass
        // the triple as the `--swift-sdk` argument when invoking the
        // build; the bundle ID (`sdk`) is only used below for
        // resolving the runtime-stdlib `.so` files we ship alongside
        // the app's binary.
        // The Swift Android SDK is keyed to an exact Swift release (its bundle
        // id embeds e.g. `swift-6.2-RELEASE-android`), and the inner
        // `swift build --swift-sdk` MUST run under a matching toolchain —
        // otherwise the SDK's prebuilt `.swiftmodule`s can't be imported
        // ("module compiled with Swift 6.2 cannot be imported by the Swift 6.0.3
        // compiler"), the ABI is skipped, and the APK ships without a Swift
        // `.so`. A repo `.swift-version` (read by swiftly) silently pins the
        // wrong toolchain for a plain `swift build`, so when swiftly is present
        // and the SDK's version is parseable we wrap the build in
        // `swiftly run +<major.minor>`, which overrides `.swift-version`.
        let buildTool = Self.androidBuildTool(sdkBundleID: sdk)
        var failures: [String] = []
        for abi in abis {
            let triple = tripleFor(abi: abi)
            do {
                // Guard the stale-incremental-cross-compile hazard: if the
                // swift-pwa runtime sources changed since this triple was last
                // built, SwiftPM's Android incremental build can leave a caller
                // module compiled against an *old* struct layout while core uses
                // the new one — producing a startup SIGSEGV (a value-witness
                // retain on a garbage field, e.g. after a field is inserted mid
                // `WindowConfig`). Fingerprint the runtime sources and wipe the
                // triple's build dir on a mismatch so the next `swift build`
                // recompiles everything against one consistent layout.
                Self.cleanStaleCrossCompileCacheIfNeeded(projectRoot: projectRoot, triple: triple)

                // `ai.local_onnx_runtime` needs `libonnxruntime.so` on
                // `LIBRARY_PATH` *for this ABI's* link step — resolved here
                // (not in `Build.applyLocalOnnxRuntimeGate`) because each ABI
                // in this loop needs a different `.so`, and setting a single
                // process-wide env var up front can't vary per iteration.
                // Reused below to stage the same `.so` into `jniLibs/<abi>/`.
                var envOverrides: [String: String]?
                var onnxLibDir: URL?
                if manifest.ai?.localOnnxRuntime == true {
                    let libDir = try await OnnxRuntimeAndroidArtifact.ensureLibDir(projectRoot: projectRoot, abi: abi)
                    onnxLibDir = libDir
                    let existing = ProcessInfo.processInfo.environment["LIBRARY_PATH"]
                    envOverrides = ["LIBRARY_PATH": existing.map { "\(libDir.path):\($0)" } ?? libDir.path]
                }

                try await Shell.run(
                    buildTool.exe,
                    buildTool.leadingArgs + ["swift", "build", "-c", "release", "--swift-sdk", triple],
                    cwd: projectRoot,
                    envOverrides: envOverrides
                )
                // SwiftPM's executable target names its output `<Name>`
                // (no `lib` prefix, no `.so` suffix) even when the
                // user's `linkerSettings` invoke `-shared` to produce
                // a shared object. The file *is* a valid Android .so —
                // `file` reports it as an ELF shared object — so we
                // copy + rename to the JNI convention here. Both
                // naming forms are checked: the bare `<Name>` is what
                // the v0.5 example pattern produces; `lib<Name>.so`
                // is what the toolchain would emit for a SwiftPM
                // library target if/when SwiftPM gains a "library
                // executable" knob.
                let candidates = [
                    projectRoot.appendingPathComponent(".build/\(triple)/release/lib\(soBaseName).so"),
                    projectRoot.appendingPathComponent(".build/\(triple)/release/\(soBaseName)"),
                    projectRoot.appendingPathComponent(".build/release/lib\(soBaseName).so"),
                    projectRoot.appendingPathComponent(".build/release/\(soBaseName)")
                ]
                guard let so = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                    failures
                        .append(
                            "\(abi): build succeeded but no \(soBaseName) / lib\(soBaseName).so output found under .build/"
                        )
                    continue
                }
                let abiDir = jniLibs.appendingPathComponent(abi)
                try FileManager.default.createDirectory(at: abiDir, withIntermediateDirectories: true)
                let stagedAppSO = abiDir.appendingPathComponent("lib\(soBaseName).so")
                try FileManager.default.copyItem(at: so, to: stagedAppSO)

                // The Swift binary `dlopen`s the Swift runtime stdlib
                // (`libswiftCore.so`, `libFoundation.so`,
                // `libdispatch.so`, etc.) plus the NDK's
                // `libc++_shared.so`. Android's loader doesn't ship
                // those, so without bundling them alongside the app's
                // own `.so` the Activity crashes at `System.loadLibrary`
                // with `UnsatisfiedLinkError: dlopen failed: library
                // "libswiftCore.so" not found`. We copy them out of
                // the SDK bundle (Swift stdlib) and the NDK sysroot
                // (libc++_shared) into `jniLibs/<abi>/` next to the
                // app's own `.so`. The set is bundled wholesale rather
                // than dependency-pruned: ~30 MB compressed in the
                // APK is acceptable for v0.5; tree-shaking based on
                // `readelf -d` is a future optimization.
                try await stageSwiftRuntime(
                    into: abiDir, abi: abi, sdkBundleId: sdk, appSO: stagedAppSO
                )
                // `ai.local_onnx_runtime`: stage the same `libonnxruntime.so`
                // that just satisfied the link step above alongside the app's
                // `.so`, or the APK crashes at launch with
                // `UnsatisfiedLinkError: libonnxruntime.so not found` — this
                // is the vendored native lib `SwiftPWASegmentation` calls the
                // ONNX Runtime C API through directly (no JNI glue).
                if let onnxLibDir {
                    let src = onnxLibDir.appendingPathComponent("libonnxruntime.so")
                    let dst = abiDir.appendingPathComponent("libonnxruntime.so")
                    if !FileManager.default.fileExists(atPath: dst.path) {
                        try FileManager.default.copyItem(at: src, to: dst)
                    }
                }
                // Strip the staged .so files. Gradle's AGP would
                // ordinarily run `stripDebugDebugSymbols` for us, but
                // it resolves the strip tool from the SDK manager's
                // NDK install (`$ANDROID_HOME/ndk/<version>/`) and
                // gives up with `Unable to strip the following
                // libraries, packaging them as they are: …` when only
                // a standalone NDK at `$ANDROID_NDK_HOME` is present
                // (the typical Swift-on-Android dev setup). Doing the
                // strip ourselves bypasses that resolution dance and
                // produces the same result the SDK-managed flow would.
                // ~40% size win — `libHelloPWA.so` 20 MB → 4 MB,
                // `libFoundation.so` 9 MB → 6 MB, `lib_FoundationICU.so`
                // 39 MB → 37 MB on the v0.5 baseline.
                try await stripELFs(in: abiDir)
            } catch {
                failures.append("\(abi): \(error)")
            }
        }
        // A requested cross-compile that produced no native library is a hard
        // failure — silently emitting a hollow scaffold (exit 0) here is what
        // let APKs ship without a Swift `.so` unnoticed. Callers who want the
        // scaffold-only behaviour pass `--no-cross-compile` (this method isn't
        // invoked then).
        if !failures.isEmpty {
            throw AndroidBundlerError.crossCompileFailed(failures)
        }
    }

    /// Resolve the executable + leading args for the inner cross-compile so it
    /// runs under a toolchain matching the installed Swift Android SDK.
    ///
    /// The SDK's prebuilt `.swiftmodule`s can only be imported by their exact
    /// Swift release; a repo `.swift-version` (read by swiftly) otherwise pins a
    /// different one for a plain `swift build`, silently skipping the ABI. When
    /// swiftly is present we invoke `<swiftly> run +<major.minor> swift build …`,
    /// which overrides `.swift-version`. We locate swiftly by its absolute path
    /// (via `SWIFTLY_BIN_DIR` / `SWIFTLY_HOME_DIR` / the platform default) rather
    /// than `PATH`, because swiftly's own `swift` shim narrows `PATH` to the
    /// selected toolchain for child processes — so a plain `env swiftly` from
    /// inside a `swift run`-launched CLI wouldn't find it. Falls back to the
    /// ambient `swift` when swiftly or the SDK version can't be resolved.
    static func androidBuildTool(sdkBundleID: String) -> (exe: String, leadingArgs: [String]) {
        let ambient = (exe: "/usr/bin/env", leadingArgs: [String]())
        guard let version = swiftVersion(fromSDKBundleID: sdkBundleID) else {
            print(
                "note: could not parse a Swift version from SDK '\(sdkBundleID)'; cross-compiling with the ambient `swift`"
            )
            return ambient
        }
        guard let swiftly = locateSwiftly() else {
            print(
                "note: swiftly not found; cross-compiling with the ambient `swift` (which must match the Swift \(version) Android SDK)"
            )
            return ambient
        }
        print(
            "cross-compiling under `swiftly run +\(version)` to match the Swift \(version) Android SDK (overrides any repo .swift-version)"
        )
        return (swiftly, ["run", "+\(version)"])
    }

    /// Absolute path to the `swiftly` binary, resolved without relying on
    /// `PATH`. Checks `SWIFTLY_BIN_DIR`, `SWIFTLY_HOME_DIR/bin`, then the
    /// per-platform default install location.
    static func locateSwiftly() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        var candidates: [String] = []
        if let bin = env["SWIFTLY_BIN_DIR"] { candidates.append("\(bin)/swiftly") }
        if let root = env["SWIFTLY_HOME_DIR"] { candidates.append("\(root)/bin/swiftly") }
        candidates.append("\(home)/.local/share/swiftly/bin/swiftly") // Linux default
        candidates.append("\(home)/Library/Application Support/swiftly/bin/swiftly") // macOS default
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Parse the `major.minor` Swift version from a Swift Android SDK bundle id,
    /// e.g. `swift-6.2-RELEASE-android-0.1` → `"6.2"`. `swiftly run +6.2`
    /// resolves that to the installed `6.2.x`.
    static func swiftVersion(fromSDKBundleID id: String) -> String? {
        guard let range = id.range(of: #"swift-[0-9]+\.[0-9]+"#, options: .regularExpression) else {
            return nil
        }
        return String(id[range].dropFirst("swift-".count))
    }

    /// Wipe `.build/<triple>` when the swift-pwa runtime sources (the shared-ABI
    /// surface) have changed since this triple was last cross-compiled, so the
    /// next `swift build` recompiles caller and library modules against one
    /// consistent struct layout.
    ///
    /// Rationale: a stored-property change in a core type (e.g. inserting a
    /// field mid-`WindowConfig`) shifts the struct's layout, but SwiftPM's
    /// Android incremental build doesn't always recompile a *caller* module that
    /// constructs the type — leaving old and new layouts linked together. The
    /// symptom is a `swift_retain` SIGSEGV in the type's value-witness copy at
    /// runtime (seen after PR #49). This is advisory-free self-healing: the
    /// common trigger — bumping the swift-pwa dependency to a version with a
    /// changed core type — is caught by the source fingerprint below, and a
    /// clean cross-compile is only forced when something actually changed.
    static func cleanStaleCrossCompileCacheIfNeeded(projectRoot: URL, triple: String) {
        let fm = FileManager.default
        let tripleDir = projectRoot.appendingPathComponent(".build/\(triple)")
        // Nothing cached yet → the upcoming build is already clean.
        guard fm.fileExists(atPath: tripleDir.path) else { return }
        let stampFile = tripleDir.appendingPathComponent(".swiftpwa-abi-fingerprint")
        let current = runtimeABIFingerprint(projectRoot: projectRoot)
        let previous = try? String(contentsOf: stampFile, encoding: .utf8)
        guard previous != current else { return }
        // Changed (or a pre-guard cache with no stamp): force a clean so no
        // stale caller object survives against the new layout.
        try? fm.removeItem(at: tripleDir)
        try? fm.createDirectory(at: tripleDir, withIntermediateDirectories: true)
        try? current.write(to: stampFile, atomically: true, encoding: .utf8)
        print(
            "note: swift-pwa runtime changed since the last \(triple) build — "
                + "cleaned .build/\(triple) to avoid a stale-layout crash"
        )
    }

    /// A stable digest of the swift-pwa runtime sources plus the CLI version.
    /// Content-based (not mtime) so a `git checkout` that doesn't change bytes
    /// doesn't force a needless clean. Falls back to the CLI version alone when
    /// the sources can't be located (still catches a dependency-version bump,
    /// since a released CLI is version-stamped).
    static func runtimeABIFingerprint(projectRoot: URL) -> String {
        var acc: UInt64 = 1_469_598_103_934_665_603 // FNV-1a offset basis
        func mix(_ s: String) {
            for byte in s.utf8 {
                acc ^= UInt64(byte)
                acc = acc &* 1_099_511_628_211
            }
        }
        mix("cli:\(SwiftPWAVersion.current)\n")
        if let sourcesRoot = locateSwiftPWASources(projectRoot: projectRoot),
           let en = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)
        {
            var files: [URL] = []
            for case let url as URL in en where url.pathExtension == "swift" {
                files.append(url)
            }
            // Sort by path so the digest is order-independent.
            for url in files.sorted(by: { $0.path < $1.path }) {
                mix(url.lastPathComponent)
                if let data = try? Data(contentsOf: url) {
                    // Fold the bytes in; cheap and content-sensitive.
                    for byte in data {
                        acc ^= UInt64(byte)
                        acc = acc &* 1_099_511_628_211
                    }
                }
            }
        }
        return String(acc, radix: 16)
    }

    /// Locate the swift-pwa runtime `Sources/` directory from a consumer
    /// project, so its ABI surface can be fingerprinted. Handles both a local
    /// `path:` dependency (this repo's `Examples/*` use `../..`) and a resolved
    /// git dependency under `.build/checkouts`. Returns `nil` if none is found.
    static func locateSwiftPWASources(projectRoot: URL) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = [
            // path dependency `../..` (the layout this repo's examples use)
            projectRoot.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources"),
            // conventional git-checkout name
            projectRoot.appendingPathComponent(".build/checkouts/swift-pwa/Sources")
        ]
        // Any other checkout dir that looks like swift-pwa (fork / rename).
        let checkouts = projectRoot.appendingPathComponent(".build/checkouts")
        if let entries = try? fm.contentsOfDirectory(at: checkouts, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.lowercased().contains("swift-pwa") {
                candidates.append(entry.appendingPathComponent("Sources"))
            }
        }
        return candidates.first {
            var isDir: ObjCBool = false
            // Confirm it's actually the runtime tree, not some unrelated Sources.
            let core = $0.appendingPathComponent("SwiftPWACore")
            return fm.fileExists(atPath: core.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Copy the Swift stdlib runtime `.so`s (`libswiftCore.so` and
    /// friends) plus the NDK's `libc++_shared.so` from the Swift
    /// Android SDK bundle into the per-ABI jniLibs directory.
    ///
    /// The Swift binary the toolchain produces is dynamically linked
    /// against the Swift runtime — Android's loader can't find those
    /// at startup unless they're packaged inside the APK alongside
    /// the app's own `.so`. Without this step, `System.loadLibrary`
    /// crashes the Activity with `UnsatisfiedLinkError: dlopen
    /// failed: library "libswiftCore.so" not found`.
    ///
    /// Default behaviour bundles the entire stdlib set wholesale —
    /// ~131 MB uncompressed APK. With `pruneRuntime` enabled, we walk
    /// the app `.so`'s `DT_NEEDED` entries transitively (via
    /// `readelf -d`) and copy only the runtime libs the binary
    /// actually loads, dropping the APK to ~30 MB on a typical app.
    /// The wholesale set includes modules most apps never touch
    /// (`_Differentiation`, `_StringProcessing`, `RegexBuilder`,
    /// `Distributed`, etc.), so the pruned variant is a 4× win for
    /// distribution.
    private func stageSwiftRuntime(
        into abiDir: URL,
        abi: String,
        sdkBundleId: String,
        appSO: URL
    ) async throws {
        let bundleRoot = swiftSDKBundleRoot(id: sdkBundleId)
        guard FileManager.default.fileExists(atPath: bundleRoot.path) else {
            print(
                "note: \(abi): Swift Android SDK bundle not found at \(bundleRoot.path); skipping runtime stdlib bundling. The APK will crash at System.loadLibrary unless you ship the runtime .so files yourself."
            )
            return
        }

        // Map ABI to the SDK's arch directory naming.
        let (sdkArchDir, ndkTripleDir) = sdkArchDirs(abi: abi)
        let runtimeDir = bundleRoot
            .appendingPathComponent("swift-resources/usr/lib/swift-\(sdkArchDir)/android")
        let ndkLibDir = bundleRoot
            .appendingPathComponent("ndk-sysroot/usr/lib/\(ndkTripleDir)")
        let cxxSharedSrc = ndkLibDir.appendingPathComponent("libc++_shared.so")

        let allRuntimeLibs = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDir.path)) ?? []
        let availableRuntime = Set(allRuntimeLibs.filter { $0.hasSuffix(".so") })

        let toStage: Set<String>
        if pruneRuntime {
            do {
                toStage = try await prunedRuntimeSet(
                    appSO: appSO,
                    runtimeDir: runtimeDir,
                    ndkLibDir: ndkLibDir,
                    available: availableRuntime
                )
                print(
                    "pruned runtime set for \(abi): \(toStage.count) of \(availableRuntime.count) Swift stdlib .so files needed"
                )
            } catch {
                // Pruning is a size optimization, not a correctness
                // requirement — if `readelf` is missing or any walk
                // step fails, fall back to the wholesale set so the
                // APK at least boots.
                print(
                    "note: \(abi): runtime prune failed (\(error)); falling back to wholesale stdlib bundle"
                )
                toStage = availableRuntime
            }
        } else {
            toStage = availableRuntime
        }

        var copied = 0
        for name in toStage {
            let src = runtimeDir.appendingPathComponent(name)
            let dst = abiDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path) { continue }
            try FileManager.default.copyItem(at: src, to: dst)
            copied += 1
        }

        // libc++_shared.so from the NDK sysroot. Required by the
        // Swift runtime libs themselves (they're C++ underneath).
        // Always copy regardless of prune mode — it's universally
        // needed and not in the runtime dir we just walked.
        let cxxSharedDst = abiDir.appendingPathComponent("libc++_shared.so")
        if FileManager.default.fileExists(atPath: cxxSharedSrc.path),
           !FileManager.default.fileExists(atPath: cxxSharedDst.path)
        {
            try FileManager.default.copyItem(at: cxxSharedSrc, to: cxxSharedDst)
            copied += 1
        }

        if copied > 0 {
            print("staged \(copied) runtime .so files into jniLibs/\(abi)/")
        }
    }

    /// Walk `appSO`'s `DT_NEEDED` entries transitively, returning the
    /// set of runtime `.so` filenames (basenames) the binary actually
    /// requires. Looks each name up in `runtimeDir` first, then
    /// `ndkLibDir` (the NDK sysroot has `libc++_shared.so`,
    /// `liblog.so`, etc.; only the Swift-runtime ones are returned for
    /// staging here — the NDK bundles ABI-stable system libs the
    /// loader resolves natively).
    ///
    /// `readelf -d` is part of the NDK's binutils and is also shipped
    /// by Xcode's command-line tools; the implementation is a pure
    /// shell-out so we don't need to drag in an ELF parser.
    private func prunedRuntimeSet(
        appSO: URL,
        runtimeDir: URL,
        ndkLibDir: URL,
        available: Set<String>
    ) async throws -> Set<String> {
        var visited: Set<String> = []
        var needed: Set<String> = []
        var queue: [URL] = [appSO]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let key = current.lastPathComponent
            if !visited.insert(key).inserted { continue }

            let deps = try await readDTNeeded(of: current)
            for dep in deps {
                // Skip Android-system libs the loader resolves itself
                // (`libc.so`, `libdl.so`, `libm.so`, `liblog.so`, etc.)
                // — they're part of the OS, not the APK.
                if isSystemLib(dep) { continue }

                if available.contains(dep) {
                    needed.insert(dep)
                    let src = runtimeDir.appendingPathComponent(dep)
                    queue.append(src)
                } else {
                    // Try the NDK sysroot — `libc++_shared.so` lives
                    // there and is staged separately, but its own
                    // DT_NEEDED chain points at libs we want to walk
                    // for completeness.
                    let ndkCandidate = ndkLibDir.appendingPathComponent(dep)
                    if FileManager.default.fileExists(atPath: ndkCandidate.path) {
                        queue.append(ndkCandidate)
                    }
                }
            }
        }
        return needed
    }

    /// Run `readelf -d <path>` and parse out the `(NEEDED) Shared
    /// library: [<name>]` lines. Returns the bare basenames in
    /// declaration order.
    ///
    /// Looks for `readelf` first (Linux hosts have it via binutils), then
    /// `llvm-readelf` (macOS hosts via the NDK's prebuilt LLVM, since
    /// macOS doesn't ship binutils — `xcrun otool -L` would work too but
    /// has a different output shape). The NDK install path is taken from
    /// `ANDROID_NDK_HOME` so the same lookup also works under CI where
    /// the env var is set explicitly.
    private func readDTNeeded(of so: URL) async throws -> [String] {
        let tool = readelfTool()
        let stdout = try await Shell.capture(tool, ["-d", so.path])
        var deps: [String] = []
        for line in stdout.split(whereSeparator: \.isNewline) {
            // Format: ` 0x...  (NEEDED)             Shared library: [libfoo.so]`
            guard line.contains("(NEEDED)") else { continue }
            guard let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"),
                  close > open
            else { continue }
            let name = String(line[line.index(after: open) ..< close])
            deps.append(name)
        }
        return deps
    }

    /// Resolve a `readelf` (or equivalent) binary on the host. Tries
    /// `readelf` on PATH first, then `llvm-readelf` on PATH, then the
    /// NDK's prebuilt `llvm-readelf` under `$ANDROID_NDK_HOME`.
    /// Falls back to `/usr/bin/env readelf` (which will fail with a
    /// clean error in `Shell.capture`) so the caller's `catch` can
    /// surface the missing-tool diagnostic.
    private func readelfTool() -> String {
        ndkBinutilsTool(name: "readelf", llvmName: "llvm-readelf") ?? "/usr/bin/env"
    }

    /// Resolve `llvm-strip` (or `strip`) the same way as `readelfTool`.
    /// Returns nil if no candidate is found — `stripELFs` skips the
    /// strip pass with a printed warning rather than failing the
    /// build.
    private func stripTool() -> String? {
        ndkBinutilsTool(name: "strip", llvmName: "llvm-strip")
    }

    private func ndkBinutilsTool(name: String, llvmName: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        // Prefer the NDK's `llvm-*` over anything on PATH. macOS's
        // `/usr/bin/strip` and `/usr/bin/readelf` (when present) are
        // Mach-O-only and choke on ELF input — `llvm-strip` /
        // `llvm-readelf` from the NDK handle ELF on every host. The NDK
        // is located by `AndroidToolchain`, so an SDK-manager install
        // (`<sdk>/ndk/<version>`) works with no `ANDROID_NDK_HOME` set.
        if let ndk = AndroidToolchain.ndk(env: env),
           let tool = AndroidToolchain.ndkTool(llvmName, ndk: ndk.path)
        {
            return tool
        }
        let pathDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        // Then `llvm-<tool>` on PATH — same ELF-vs-Mach-O reasoning.
        var candidates = [llvmName]
        #if !os(macOS)
            // A bare `strip` / `readelf` is binutils on Linux/Windows and
            // handles ELF. On macOS it is *always* Xcode's Mach-O strip,
            // which exits 1 on `--strip-unneeded` for every file — the APK
            // then ships ~130 MB of unstripped `.so` with nothing but a
            // `note:` per library to say so. Never accept it there.
            candidates.append(name)
        #endif
        for candidate in candidates {
            for dir in pathDirs {
                let path = "\(dir)/\(candidate)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    /// Strip every `.so` file under `dir` with `llvm-strip
    /// --strip-unneeded`. Done in-place; the unstripped `.build/`
    /// copy stays on disk for `swift symbolicate` consumption.
    /// Skips the pass with a one-line warning if no strip tool is
    /// resolvable — pruning still gives the prune flag's win in
    /// that case, just without the symbol-table cull.
    private func stripELFs(in dir: URL) async throws {
        guard let tool = stripTool() else {
            print(
                "warning: no `llvm-strip` found under the Android NDK or on PATH; APK will ship unstripped .so files (~40% larger). Install the NDK (or set ANDROID_NDK_HOME) to enable."
            )
            return
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var before: Int64 = 0
        var after: Int64 = 0
        var stripped = 0
        for name in entries where name.hasSuffix(".so") {
            let path = dir.appendingPathComponent(name).path
            let beforeSize = fileSize(path)
            before += beforeSize
            do {
                _ = try await Shell.capture(tool, ["--strip-unneeded", path], discardStderr: true)
            } catch {
                after += beforeSize
                // One failure means the *tool* is wrong far more often
                // than the file is (a Mach-O `strip` rejecting
                // `--strip-unneeded` fails identically on all ~30
                // libraries). Bail on the first one with a warning that
                // names the tool, rather than emitting a per-file `note:`
                // and a "saved 0 MB, 0%" line that reads like success.
                if stripped == 0 {
                    print(
                        "warning: `\(tool)` failed on \(name) (\(error)); skipping the strip pass — "
                            + "the APK will ship unstripped .so files (~40% larger)."
                    )
                    return
                }
                print("note: strip failed on \(name): \(error)")
                continue
            }
            stripped += 1
            after += fileSize(path)
        }
        if before > 0 {
            let saved = before - after
            let pct = Int((Double(saved) / Double(before)) * 100.0)
            print(
                "stripped jniLibs in \(dir.lastPathComponent): \(formatBytes(before)) → \(formatBytes(after)) (saved \(formatBytes(saved)), \(pct)%)"
            )
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }

    /// Read a file's size with the optional-chain unambiguous —
    /// `FileManager.attributesOfItem(...)[.size]` returns
    /// `Any?` boxing a numeric value, and the cast path through
    /// `try?` + `as? Int64` interacts badly enough with Swift's
    /// implicit optional flattening that an inline expression can
    /// silently always-fail one side of the chain.
    private func fileSize(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    /// Is `name` a stock Android / NDK system library that the
    /// platform loader resolves without us shipping it? These names
    /// are guaranteed to exist on every Android device ≥ API 28 and
    /// must NOT be shipped in the APK (Bionic refuses to load a
    /// duplicate of `libc.so` from `jniLibs/`).
    private func isSystemLib(_ name: String) -> Bool {
        let stable: Set = [
            "libc.so", "libdl.so", "libm.so", "libz.so",
            "liblog.so", "libandroid.so",
            "libstdc++.so", "libgcc_s.so",
            "libnetd_client.so",
            "ld-android.so", "linker", "linker64"
        ]
        return stable.contains(name)
    }

    /// Standard install path for a Swift SDK bundle, resolved against the
    /// **host** OS running this CLI (the machine doing the cross-compile).
    /// SwiftPM's swift-sdks root is platform-dependent:
    /// `~/Library/org.swift.swiftpm/swift-sdks` on macOS,
    /// `${XDG_DATA_HOME:-~/.local/share}/swiftpm/swift-sdks` on Linux. Getting
    /// this wrong silently skips runtime-stdlib bundling, producing an APK
    /// that crashes at `System.loadLibrary` on-device (it still *assembles*,
    /// so CI's assemble-only check never catches it).
    private func swiftSDKBundleRoot(id: String) -> URL {
        let leaf = "\(id).artifactbundle/swift-android"
        // SwiftPM's swift-sdks root varies by host *and* by SwiftPM version /
        // install method, so probe the known roots and use whichever actually
        // holds the bundle. Order: legacy `~/.swiftpm` (what swiftly-managed
        // toolchains use today), the XDG location, then macOS. Getting this
        // wrong silently skips runtime-stdlib bundling — the APK assembles but
        // crashes at `System.loadLibrary` on-device (CI's assemble-only check
        // never catches it).
        let fm = FileManager.default
        let candidates = swiftSDKRootCandidates()
        for root in candidates {
            let bundle = root.appendingPathComponent(leaf)
            if fm.fileExists(atPath: bundle.path) { return bundle }
        }
        // None found — return the first candidate so the "not found" note
        // points at the most likely location for this host.
        return (candidates.first ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent(leaf)
    }

    /// Candidate SwiftPM swift-sdks roots, most-likely first.
    private func swiftSDKRootCandidates() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var roots: [URL] = []
        #if os(macOS)
            roots.append(home.appendingPathComponent("Library/org.swift.swiftpm/swift-sdks"))
        #endif
        // Legacy data dir — used by swiftly-managed toolchains today.
        roots.append(home.appendingPathComponent(".swiftpm/swift-sdks"))
        // XDG location (newer SwiftPM): $XDG_DATA_HOME ?? ~/.local/share.
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            roots.append(URL(fileURLWithPath: xdg).appendingPathComponent("swiftpm/swift-sdks"))
        }
        roots.append(home.appendingPathComponent(".local/share/swiftpm/swift-sdks"))
        return roots
    }

    /// Map an Android ABI to the SDK's per-arch directory names:
    /// the Swift-resource arch (used in `swift-<arch>/`) and the
    /// NDK target triple (used in `ndk-sysroot/usr/lib/<triple>/`).
    private func sdkArchDirs(abi: String) -> (swiftArch: String, ndkTriple: String) {
        switch abi {
        case "arm64-v8a": ("aarch64", "aarch64-linux-android")
        case "armeabi-v7a": ("armv7", "arm-linux-androideabi")
        case "x86_64": ("x86_64", "x86_64-linux-android")
        case "x86": ("i686", "i686-linux-android")
        default: ("aarch64", "aarch64-linux-android")
        }
    }

    /// Run `swift sdk list` and return the first SDK whose name
    /// contains "android". Nil if none installed (or if the
    /// invocation fails — pre-Swift-5.9 toolchains don't have the
    /// subcommand at all, in which case Android cross-compile from
    /// the swift-pwa CLI isn't supported regardless).
    private func detectAndroidSwiftSDK() async -> String? {
        guard let stdout = try? await Shell.capture("/usr/bin/env", ["swift", "sdk", "list"]) else {
            return nil
        }
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().contains("android"), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// Merge the manifest's `android.signing` section with the CLI
    /// overrides (`--sign <keystore>` and `--android-key-alias`) into
    /// the resolved `AndroidTemplates.SigningConfig?` the template
    /// understands. Returns `nil` if neither side configures signing
    /// — the generated scaffold then matches the pre-v0.5.x behavior
    /// (debug-only signing; `assembleRelease` would refuse without a
    /// signingConfig). Throws if the configuration is partial — e.g.
    /// `--sign` set but no alias resolvable from anywhere — since
    /// silently dropping the option would surprise the user.
    func resolveSigning() throws -> AndroidTemplates.SigningConfig? {
        let manifestSigning = manifest.android?.signing
        let keystoreRaw = signKeystoreOverride ?? manifestSigning?.keystore
        let alias = keyAliasOverride ?? manifestSigning?.keyAlias
        guard let keystoreRaw else { return nil }
        guard let alias, !alias.isEmpty else {
            throw AndroidBundlerError.signingMissingAlias
        }
        let keystoreAbs = resolveAbsolutePath(keystoreRaw)
        let storeType = manifestSigning?.storeType?.lowercased() ?? "jks"
        switch storeType {
        case "jks", "pkcs12":
            break
        default:
            throw AndroidBundlerError.signingUnknownStoreType(storeType)
        }
        return AndroidTemplates.SigningConfig(
            keystoreAbsolutePath: keystoreAbs,
            keyAlias: alias,
            storeType: storeType,
            v1SigningEnabled: manifestSigning?.v1SigningEnabled ?? true,
            v2SigningEnabled: manifestSigning?.v2SigningEnabled ?? true
        )
    }

    /// Turn a possibly-relative path into an absolute one, anchored
    /// at `projectRoot`. The bundler resolves at scaffold time so the
    /// generated `app/build.gradle.kts` (which lives a directory deeper
    /// under `build/<name>-android/app/`) doesn't need to compute the
    /// path itself — `file("absolute-path")` is unambiguous regardless
    /// of where Gradle is invoked from.
    private func resolveAbsolutePath(_ raw: String) -> String {
        if raw.hasPrefix("/") || raw.contains(":\\") {
            return raw // already absolute (POSIX or Windows)
        }
        return projectRoot.appendingPathComponent(raw).standardizedFileURL.path
    }

    private func tripleFor(abi: String) -> String {
        // Swift Android SDK 6.2 supports API 28–36 (Android 9+); the
        // older API 24 floor was dropped in that release. Anything
        // below 28 here would silently miss the bundle's
        // `targetTriples` map and SwiftPM would fall back to a
        // wrong-arch resource path. Clamp to 28 even if the
        // manifest's `min_sdk` is lower, and print a one-shot warning
        // so the developer knows to bump it.
        let configured = manifest.android?.minSdk ?? 28
        let api = max(configured, 28)
        if configured < 28 {
            print(
                "note: pwa.json's android.min_sdk = \(configured) is below the Swift Android SDK 6.2 floor (API 28); using android\(api) for the cross-compile triple. Update min_sdk to 28+ to silence this."
            )
        }
        switch abi {
        case "arm64-v8a": return "aarch64-unknown-linux-android\(api)"
        case "armeabi-v7a": return "armv7-unknown-linux-androideabi\(api)"
        case "x86_64": return "x86_64-unknown-linux-android\(api)"
        case "x86": return "i686-unknown-linux-android\(api)"
        default: return "aarch64-unknown-linux-android\(api)"
        }
    }
}

/// Errors the Android bundler raises when its inputs don't make
/// sense. Kept narrow — most of the bundler's failure paths are
/// printed-and-continue (`note:` lines for missing optional pieces),
/// so reaching this enum means the user supplied a config that's
/// actively contradictory and silent fallback would be worse than
/// failing the build.
enum AndroidBundlerError: Error, CustomStringConvertible {
    case signingMissingAlias
    case signingUnknownStoreType(String)
    case crossCompileFailed([String])

    var description: String {
        switch self {
        case .signingMissingAlias:
            """
            swift-pwa: release signing was requested (--sign or pwa.json's \
            android.signing.keystore is set) but no key alias is available. \
            Set pwa.json's android.signing.key_alias or pass --android-key-alias.
            """
        case let .signingUnknownStoreType(t):
            "swift-pwa: pwa.json's android.signing.store_type='\(t)' is not recognized; expected 'jks' or 'pkcs12'."
        case let .crossCompileFailed(failures):
            """
            swift-pwa: --cross-compile-android could not produce a native library for \
            \(failures.count == 1 ? "the requested ABI" : "\(failures.count) requested ABIs"). \
            The APK would ship without a Swift .so and crash at launch \
            (UnsatisfiedLinkError), so this is a hard error rather than a warning:
            \(failures.map { "  - \($0)" }.joined(separator: "\n"))
            Common cause: the inner `swift build --swift-sdk` ran under a Swift \
            toolchain that doesn't match the installed Swift Android SDK (a repo \
            `.swift-version` can pin the wrong one — see \
            "module compiled with Swift X cannot be imported by the Swift Y compiler" \
            above). Install/select the matching toolchain, or pass \
            --no-cross-compile to emit the Gradle scaffold without native libs.
            """
        }
    }
}
