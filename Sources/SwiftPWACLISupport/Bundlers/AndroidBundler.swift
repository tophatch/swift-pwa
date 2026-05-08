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

    func build() async throws -> URL {
        let project = outputDir.appendingPathComponent("\(manifest.name)-android")
        if FileManager.default.fileExists(atPath: project.path) {
            try FileManager.default.removeItem(at: project)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let pkg = androidPackageId()
        let label = manifest.name
        let versionName = manifest.version
        let versionCode = manifest.android?.versionCode ?? 1
        let minSdk = manifest.android?.minSdk ?? 28
        let targetSdk = manifest.android?.targetSdk ?? 34

        // Project-level files.
        let settings = AndroidTemplates.settingsGradleKts(label: label)
        try settings.write(
            to: project.appendingPathComponent("settings.gradle.kts"),
            atomically: true, encoding: .utf8
        )
        try AndroidTemplates.rootBuildGradleKts.write(
            to: project.appendingPathComponent("build.gradle.kts"),
            atomically: true, encoding: .utf8
        )
        try AndroidTemplates.gradleProperties.write(
            to: project.appendingPathComponent("gradle.properties"),
            atomically: true, encoding: .utf8
        )

        // App module.
        let app = project.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try AndroidTemplates.appBuildGradleKts(
            packageId: pkg,
            versionCode: versionCode,
            versionName: versionName,
            minSdk: minSdk,
            targetSdk: targetSdk,
            abis: abis,
            soBaseName: soBaseName()
        ).write(
            to: app.appendingPathComponent("build.gradle.kts"),
            atomically: true, encoding: .utf8
        )

        // src/main layout.
        let main = app.appendingPathComponent("src/main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try AndroidTemplates.androidManifestXml(packageId: pkg, label: label).write(
            to: main.appendingPathComponent("AndroidManifest.xml"),
            atomically: true, encoding: .utf8
        )

        // Kotlin sources go under `java/<package-as-path>/...`
        let kotlinDir = main.appendingPathComponent("java/" + pkg.replacingOccurrences(of: ".", with: "/"))
        try FileManager.default.createDirectory(at: kotlinDir, withIntermediateDirectories: true)
        try AndroidTemplates.mainActivityKt(packageId: pkg, soBaseName: soBaseName()).write(
            to: kotlinDir.appendingPathComponent("MainActivity.kt"),
            atomically: true, encoding: .utf8
        )
        // The bridge class lives under a stable package
        // (`dev.swiftpwa.runtime`) because the JNI shim's exported
        // symbols are mangled with that name; user code shouldn't
        // shadow or rewrap it.
        let runtimeDir = main.appendingPathComponent("java/dev/swiftpwa/runtime")
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try AndroidTemplates.swiftPWABridgeKt.write(
            to: runtimeDir.appendingPathComponent("SwiftPWABridge.kt"),
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

        // Copy bridge.js from SwiftPWACore's resource bundle alongside
        // the assets so the Kotlin host can inject it on page-start.
        // `BridgeScript.source()` is the same helper the runtime
        // backends use; it reads from SwiftPWACore's `Bundle.module`,
        // so we get the canonical text regardless of where the CLI
        // was invoked from. (The previous version walked the
        // filesystem from the user's project root looking for the
        // checked-in source file, which broke whenever the CLI ran
        // from a binary install or from a project that wasn't a
        // sibling/parent of the swift-pwa checkout.)
        let bridgeJsDst = assets.appendingPathComponent("swift_pwa/bridge.js")
        try FileManager.default.createDirectory(
            at: bridgeJsDst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bridgeJs = try BridgeScript.source()
        try bridgeJs.write(to: bridgeJsDst, atomically: true, encoding: .utf8)

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
            try await stageJniLibs(into: app)
        } else {
            print(
                "note: --no-cross-compile in effect; jniLibs/ will be empty until you run `swift build --triple <android>` and copy the .so files manually"
            )
        }

        return project
    }

    /// Copy the vendored Gradle wrapper into the generated project.
    /// The resource directory lives under
    /// `Sources/SwiftPWACLISupport/Bundlers/AndroidWrapperResources/`
    /// and contains:
    ///   - `gradlew` (Unix shell script — needs +x at the destination)
    ///   - `gradlew.bat` (Windows batch script)
    ///   - `gradle/wrapper/gradle-wrapper.jar` (the bootstrap JAR;
    ///     ~48 KB; pinned to Gradle 8.10.2 via the properties file)
    ///   - `gradle/wrapper/gradle-wrapper.properties`
    private func stageGradleWrapper(into project: URL) throws {
        // SwiftPM's `.copy("Bundlers/AndroidWrapperResources")` puts
        // the named directory verbatim in the resource bundle under
        // its last path component. Locate it via `Bundle.module`.
        guard let resourceRoot = Bundle.module.url(
            forResource: "AndroidWrapperResources", withExtension: nil
        ) else {
            // The CLI was built without the wrapper resource — most
            // likely because the user is building swift-pwa-cli from a
            // pre-vendored checkout. Surface a clear note and continue
            // emitting the rest of the scaffold; the user can drop a
            // wrapper in by hand or run `gradle wrapper` themselves.
            print(
                "note: vendored Gradle wrapper not found in CLI bundle; the generated project won't include `./gradlew`. Run `gradle wrapper` from the project directory once a system Gradle is installed."
            )
            return
        }

        let gradlewSrc = resourceRoot.appendingPathComponent("gradlew")
        let gradlewBatSrc = resourceRoot.appendingPathComponent("gradlew.bat")
        let wrapperDirSrc = resourceRoot.appendingPathComponent("gradle/wrapper")

        let gradlewDst = project.appendingPathComponent("gradlew")
        let gradlewBatDst = project.appendingPathComponent("gradlew.bat")
        let wrapperDirDst = project.appendingPathComponent("gradle/wrapper")

        try FileManager.default.createDirectory(
            at: wrapperDirDst, withIntermediateDirectories: true
        )

        try FileManager.default.copyItem(at: gradlewSrc, to: gradlewDst)
        try FileManager.default.copyItem(at: gradlewBatSrc, to: gradlewBatDst)

        // Copy the two files inside `gradle/wrapper/`.
        for name in ["gradle-wrapper.jar", "gradle-wrapper.properties"] {
            let src = wrapperDirSrc.appendingPathComponent(name)
            let dst = wrapperDirDst.appendingPathComponent(name)
            try FileManager.default.copyItem(at: src, to: dst)
        }

        // chmod +x on `gradlew`. SwiftPM's `.copy` rule preserves the
        // source file's permissions on Apple, but cross-platform we
        // can't rely on that — explicitly set the executable bits.
        let attrs: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o755))
        ]
        try FileManager.default.setAttributes(attrs, ofItemAtPath: gradlewDst.path)
    }

    // MARK: - Helpers

    private func androidPackageId() -> String {
        if let configured = manifest.android?.packageId, !configured.isEmpty {
            return configured
        }
        // Fall back to the top-level id if it looks like a package
        // id; otherwise namespace under `dev.swiftpwa.<id>` (lowercase
        // alphanumerics only).
        let id = manifest.id
        if id.contains(".") {
            return id
        }
        let cleaned = id.unicodeScalars.compactMap { sc -> Character? in
            if CharacterSet.alphanumerics.contains(sc) { return Character(sc) }
            return nil
        }
        return "dev.swiftpwa." + String(cleaned).lowercased()
    }

    /// `lib<name>.so` is what Android's loader expects under
    /// `jniLibs/<abi>/`. SwiftPM's executable target on Android
    /// produces `lib<TargetName>.so` once the user's package is
    /// configured to build a shared object (see
    /// `docs/android-setup.md`).
    private func soBaseName() -> String {
        manifest.name
    }

    private func stageJniLibs(into appModule: URL) async throws {
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
        var failures: [String] = []
        for abi in abis {
            let triple = tripleFor(abi: abi)
            do {
                try await Shell.run(
                    "/usr/bin/env",
                    ["swift", "build", "-c", "release", "--swift-sdk", triple],
                    cwd: projectRoot
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
                    projectRoot.appendingPathComponent(".build/\(triple)/release/lib\(soBaseName()).so"),
                    projectRoot.appendingPathComponent(".build/\(triple)/release/\(soBaseName())"),
                    projectRoot.appendingPathComponent(".build/release/lib\(soBaseName()).so"),
                    projectRoot.appendingPathComponent(".build/release/\(soBaseName())")
                ]
                guard let so = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                    failures
                        .append(
                            "\(abi): build succeeded but no \(soBaseName()) / lib\(soBaseName()).so output found under .build/"
                        )
                    continue
                }
                let abiDir = jniLibs.appendingPathComponent(abi)
                try FileManager.default.createDirectory(at: abiDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: so, to: abiDir.appendingPathComponent("lib\(soBaseName()).so"))

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
                try stageSwiftRuntime(into: abiDir, abi: abi, sdkBundleId: sdk)
            } catch {
                failures.append("\(abi): \(error)")
            }
        }
        if !failures.isEmpty {
            print("note: some Android ABIs were skipped:")
            for line in failures { print("  - \(line)") }
            print(
                "The Gradle scaffold is still usable; copy the missing .so files into app/src/main/jniLibs/<abi>/ once your toolchain can produce them."
            )
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
    /// We bundle the entire stdlib set rather than pruning by what
    /// the binary actually uses — typical Swift-on-Android apps pull
    /// most of it transitively, and the ~30 MB compressed APK cost
    /// is acceptable for the v0.5 preview. A later
    /// `--prune-runtime` flag can `readelf -d` the binary and copy
    /// only the transitive `DT_NEEDED` set.
    private func stageSwiftRuntime(into abiDir: URL, abi: String, sdkBundleId: String) throws {
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
        let cxxSharedSrc = bundleRoot
            .appendingPathComponent("ndk-sysroot/usr/lib/\(ndkTripleDir)/libc++_shared.so")

        // Swift stdlib: copy every `.so` from the runtime dir.
        let runtimeContents = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDir.path)) ?? []
        var copied = 0
        for name in runtimeContents where name.hasSuffix(".so") {
            let src = runtimeDir.appendingPathComponent(name)
            let dst = abiDir.appendingPathComponent(name)
            // Skip if already present (rare but possible if a
            // previous run dropped one in by hand).
            if FileManager.default.fileExists(atPath: dst.path) { continue }
            try FileManager.default.copyItem(at: src, to: dst)
            copied += 1
        }

        // libc++_shared.so from the NDK sysroot. Required by the
        // Swift runtime libs themselves (they're C++ underneath).
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

    /// Standard install path for a Swift SDK bundle. macOS only for
    /// now; Linux uses `~/.swiftpm/swift-sdks/...` and would need a
    /// per-OS branch added here.
    private func swiftSDKBundleRoot(id: String) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home
            .appendingPathComponent("Library/org.swift.swiftpm/swift-sdks")
            .appendingPathComponent("\(id).artifactbundle/swift-android")
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
