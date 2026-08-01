import ArgumentParser
import Foundation

/// `deploy` = `build` → package/assemble → install → launch, in one step.
///
/// `build` produces an artifact; nothing today carries it the last mile onto a
/// device or a running process. That last mile is per-platform and error-prone
/// (Android alone is `gradlew assembleDebug` → `adb install` → `am start`, with
/// wireless-connect and device-selection papercuts), which is exactly the kind
/// of thing a CLI verb should absorb. `deploy` is a *superset* of `build`: every
/// `build` flag it needs is passed through, and the deploy-only additions
/// (`--device`, `--no-build`, `--launch`/`--no-launch`, `--reinstall`) are the
/// install/launch controls.
///
/// It reuses `build` wholesale — it runs the real `build` (via `Build.parse`),
/// so the preflight, AI gates, prebuild, web-bundle check, bundler, and
/// postbuild all behave identically — then owns the steps `build` deliberately
/// doesn't: invoking Gradle (`build --target android` stages an offline-complete
/// project but never runs it), installing (`adb` / `simctl` / `devicectl`), and
/// launching.
struct Deploy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deploy",
        abstract: "Build, install, and launch the app on a device or the host.",
        discussion: """
        Runs the full last-mile per platform:
          • android  — cross-compile → ./gradlew assembleDebug → adb install -r → am start
          • ios      — --simulator: build → boot a sim → simctl install/launch;
                       device: signed build (--team …) → devicectl install → launch
          • macos    — build → open the .app
          • linux    — build → run the AppImage
          • windows  — build → run the portable .exe

        Device selection is by the platform's own rules: the sole connected device by default; \
        --device (or ANDROID_SERIAL on Android) to choose; a clear error — never a silent pick — \
        when several are attached and none is chosen.
        """
    )

    @Option(
        help: """
        Target platform: \(BuildTarget.allCases.map(\.rawValue).joined(separator: ", ")). \
        Defaults to the host machine (\(BuildTarget.host.rawValue)) when omitted.
        """
    )
    var target: BuildTarget = .host

    @Option(help: "Path to pwa.json. Defaults to ./pwa.json.")
    var manifest: String = "pwa.json"

    @Option(help: "Output directory for the bundled artifact. Defaults to ./build.")
    var output: String = "build"

    @Option(
        name: .long,
        help: """
        Which device to deploy to. Android: an adb serial, or an ip:port for a wireless \
        device (deploy runs `adb connect` first). iOS device: a UDID or device name. \
        iOS simulator: a simulator name or UDID. Honors ANDROID_SERIAL when omitted for Android.
        """
    )
    var device: String?

    @Flag(help: "iOS: target a simulator (skips signing) instead of a physical device.")
    var simulator: Bool = false

    @Option(
        help: """
        Comma-separated Android ABIs to include (e.g. arm64-v8a,x86_64). Overrides pwa.json's \
        android.abis. Passed through to the build.
        """
    )
    var androidAbis: String?

    @Flag(
        name: .long,
        help: "Skip the build/package step and install/launch the already-built artifact (the fast re-test path)."
    )
    var noBuild: Bool = false

    @Flag(
        inversion: .prefixedNo,
        help: "Launch the app after installing (default). --no-launch installs without foregrounding it."
    )
    var launch: Bool = true

    @Flag(
        inversion: .prefixedNo,
        help: "Android: install with -r (replace/keep data), the default. --no-reinstall does a plain install."
    )
    var reinstall: Bool = true

    @Flag(help: "Android: assemble the release variant instead of debug. (A release APK must be signed to install.)")
    var release: Bool = false

    // iOS on-device signing — passed straight through to the underlying `build`
    // (same semantics as `swift-pwa build --target ios`). An on-device install
    // needs a signed .app; the simplest path is --team (finds an installed
    // identity + profile for the bundle id), else pass the pieces explicitly.

    @Option(
        help: """
        iOS device: a 10-character Apple Developer Team ID. Fills in the signing identity + \
        provisioning profile you didn't pass. See docs/ios-setup.md.
        """
    )
    var team: String?

    @Option(help: "iOS/macOS: codesign identity (e.g. \"Apple Development: …\"). Passed through to the build.")
    var sign: String?

    @Option(help: "iOS device: path to a provisioning profile (.mobileprovision), embedded into the app.")
    var provisioningProfile: String?

    @Option(help: "iOS device: path to an entitlements plist signed into the app (pair with --provisioning-profile).")
    var entitlements: String?

    @Flag(
        name: .long,
        help: """
        iOS device: allow --team to mint a provisioning profile for a free personal Apple team \
        (builds a throwaway project against the target device, registering it). Passed through to \
        the build; echoes xcodebuild's -allowProvisioningDeviceRegistration.
        """
    )
    var allowProvisioningRegistration: Bool = false

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = cwd.appendingPathComponent(manifest)
        let outputDir = cwd.appendingPathComponent(output)
        let pwa = try PWAManifest.load(from: manifestURL)

        switch target {
        case .android:
            try await deployAndroid(pwa: pwa, projectRoot: cwd, outputDir: outputDir)
        case .ios:
            try await deployIOS(pwa: pwa, outputDir: outputDir)
        case .macos:
            try await deployMac(pwa: pwa, outputDir: outputDir)
        case .linux, .windows:
            try await deployDesktopBinary(pwa: pwa, projectRoot: cwd, outputDir: outputDir)
        }
    }

    // MARK: - build reuse

    /// Run the standard `build` pipeline for `target`, so `deploy` inherits its
    /// preflight, AI gates, prebuild, web-bundle check, and postbuild verbatim.
    /// Android deploy always cross-compiles — an installable APK needs the `.so`.
    ///
    /// Constructed through `Build.parse(_:)` rather than `Build()`: an
    /// ArgumentParser command's `@Option`/`@Flag` properties are only bound by
    /// its parser, so a plain init leaves them unbound and accessing one traps.
    private func runBuild(crossCompileAndroid: Bool, iosDeviceUDID: String? = nil) async throws {
        var args = ["--target", target.rawValue, "--manifest", manifest, "--output", output]
        if simulator { args.append("--simulator") }
        if crossCompileAndroid { args.append("--cross-compile-android") }
        if let androidAbis { args += ["--android-abis", androidAbis] }
        // iOS device signing pass-through (ignored by build for other targets).
        if let team { args += ["--team", team] }
        if let sign { args += ["--sign", sign] }
        if let provisioningProfile { args += ["--provisioning-profile", provisioningProfile] }
        if let entitlements { args += ["--entitlements", entitlements] }
        if let iosDeviceUDID { args += ["--device", iosDeviceUDID] }
        if allowProvisioningRegistration { args.append("--allow-provisioning-registration") }
        // deploy runs gradlew / the launch itself, so build's "Next: …" hint would mislead.
        args.append("--no-next-steps")
        let build = try Build.parse(args)
        try await build.run()
    }

    // MARK: - Android

    private func deployAndroid(pwa: PWAManifest, projectRoot: URL, outputDir: URL) async throws {
        // adb is mandatory for a device install — fail fast with a fix rather
        // than deep in an install step. Build prerequisites (NDK/JDK/Swift SDK)
        // reuse build's own heads-up preflight when we're building.
        guard await Self.toolOnPath("adb") else {
            throw ValidationError(
                "`adb` is not on PATH — it's required to install on a device. Install the Android "
                    + "platform-tools and add them to PATH (macOS: `brew install --cask android-platform-tools`)."
            )
        }

        let project = Self.androidProjectDir(outputDir: outputDir, pwa: pwa)
        if !noBuild {
            // Resolve Gradle's toolchain *before* the (minutes-long)
            // cross-compile: a missing JDK or SDK is otherwise discovered at
            // the very end, as a raw Gradle error, with the whole build wasted.
            let gradle = try await Self.resolveGradleToolchain()
            // runBuild → Build.run() already emits the doctor heads-up preflight.
            try await runBuild(crossCompileAndroid: true)
            try await assembleAPK(project: project, envOverrides: gradle)
        }

        let apk = try Self.resolveAPK(project: project, release: release)
        print("→ APK: \(apk.path)")

        let serial = try await resolveAndroidSerial()
        print("→ installing to \(serial) (a large asset bundle can take a few minutes over wifi)")
        var installArgs = ["-s", serial, "install"]
        if reinstall { installArgs.append("-r") }
        installArgs.append(apk.path)
        try await Shell.run("adb", installArgs)

        if launch {
            let pkg = AndroidEntryDrift.resolvePackageId(pwa)
            let component = "\(pkg)/.MainActivity"
            print("→ launching \(component)")
            try await Shell.run("adb", ["-s", serial, "shell", "am", "start", "-n", component, "-W"])
        }
        print("Deployed to \(serial).")
    }

    /// Invoke the staged Gradle project's `gradlew` — the step `build`
    /// deliberately leaves to the caller.
    private func assembleAPK(project: URL, envOverrides: [String: String]) async throws {
        let gradlew = project.appendingPathComponent("gradlew")
        guard FileManager.default.fileExists(atPath: gradlew.path) else {
            throw ValidationError(
                "no Gradle project at \(project.path) — the Android build didn't stage it. "
                    + "Run without --no-build."
            )
        }
        let task = release ? "assembleRelease" : "assembleDebug"
        print("→ assembling the \(release ? "release" : "debug") APK (./gradlew \(task))")
        try await Shell.run(gradlew.path, [task], cwd: project, envOverrides: envOverrides.isEmpty ? nil : envOverrides)
    }

    /// Locate the JDK and Android SDK Gradle needs, returning the env
    /// overrides that point `gradlew` at them (empty when the ambient
    /// environment already has both).
    ///
    /// Throws with the fix rather than letting Gradle fail: its own messages
    /// for these two gaps are `Unable to locate a Java Runtime` (from macOS's
    /// `/usr/bin/java` stub — so a PATH check doesn't catch it) and `SDK
    /// location not found`, neither of which mentions swift-pwa or how a
    /// working install is normally laid out.
    private static func resolveGradleToolchain() async throws -> [String: String] {
        let java = await AndroidToolchain.resolveJava()
        if java == .missing {
            throw ValidationError(
                "no JDK found — Gradle can't assemble the APK without one. Install JDK 17 and either "
                    + "put `java` on PATH or set JAVA_HOME (macOS: `brew install openjdk@17`, which is "
                    + "keg-only — swift-pwa finds it there; Linux: `apt install openjdk-17-jdk`). "
                    + "Android Studio's bundled JBR counts too."
            )
        }
        guard let sdk = AndroidToolchain.sdk() else {
            throw ValidationError(
                "no Android SDK found — Gradle needs one to build the APK. Install it (Android Studio, "
                    + "or the command-line tools) and set ANDROID_HOME, or put it in the standard location "
                    + "(macOS: ~/Library/Android/sdk, Linux: ~/Android/Sdk)."
            )
        }
        if case let .discovered(jdk) = java { print("→ JDK: \(jdk.path)") }
        return AndroidToolchain.gradleEnvironment(java: java, sdk: sdk)
    }

    private static func androidProjectDir(outputDir: URL, pwa: PWAManifest) -> URL {
        outputDir.appendingPathComponent("\(pwa.name)-android")
    }

    /// The assembled APK under the standard Gradle output layout. Prefers the
    /// conventional `app-<variant>.apk`, else the first `.apk` in the variant
    /// dir (a release variant can be `app-release-unsigned.apk`).
    private static func resolveAPK(project: URL, release: Bool) throws -> URL {
        let variant = release ? "release" : "debug"
        let apkDir = project.appendingPathComponent("app/build/outputs/apk/\(variant)")
        let preferred = apkDir.appendingPathComponent("app-\(variant).apk")
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        let apks = ((try? FileManager.default.contentsOfDirectory(atPath: apkDir.path)) ?? [])
            .filter { $0.hasSuffix(".apk") }
            .sorted()
        guard let first = apks.first else {
            throw ValidationError(
                "no APK found under \(apkDir.path). Assemble it first (run without --no-build), "
                    + "or check that the \(variant) variant built."
            )
        }
        return apkDir.appendingPathComponent(first)
    }

    /// Resolve the target adb serial by adb's own rules: an ip:port `--device`
    /// is `adb connect`-ed first and used as the serial; an explicit serial or
    /// `ANDROID_SERIAL` is honored; otherwise the sole connected device is used
    /// and any ambiguity is a clear error, never a silent pick.
    private func resolveAndroidSerial() async throws -> String {
        if let device, device.contains(":") {
            print("→ adb connect \(device)")
            // `adb connect` exits 0 even when it can't reach the device (it just
            // prints "failed to connect …" / "cannot connect …"), so capture and
            // validate rather than pressing on and failing later in `adb install`
            // with a more confusing message.
            let out = await (try? Shell.capture("adb", ["connect", device])) ?? ""
            let lower = out.lowercased()
            if lower.contains("failed to connect") || lower.contains("cannot connect") {
                throw ValidationError(
                    "adb could not connect to \(device): \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }
            return device
        }
        if let device { return device }
        if let envSerial = ProcessInfo.processInfo.environment["ANDROID_SERIAL"], !envSerial.isEmpty {
            return envSerial
        }
        let serials = try await Self.connectedAndroidSerials()
        switch serials.count {
        case 0:
            throw ValidationError(
                "no Android device connected. Attach one and enable USB/wireless debugging, or pass "
                    + "--device <serial|ip:port> (a wireless device: --device <ip:port>)."
            )
        case 1:
            return serials[0]
        default:
            throw ValidationError(
                "\(serials.count) Android devices are connected: \(serials.joined(separator: ", ")). "
                    + "Pass --device <serial> (or set ANDROID_SERIAL) to choose one."
            )
        }
    }

    /// Serials of devices in the `device` state (excludes `offline` /
    /// `unauthorized`), parsed from `adb devices`.
    ///
    /// Each row is `<serial>\t<state>` — tab-separated, not
    /// whitespace-separated: an mDNS/TLS serial such as
    /// `adb-SERIAL (2)._adb-tls-connect._tcp` contains a space, so a whitespace
    /// split would mangle it (and, worse, silently drop it and hide a real
    /// multi-device ambiguity). Split on tab and take the last column as the
    /// state.
    private static func connectedAndroidSerials() async throws -> [String] {
        let out = try await Shell.capture("adb", ["devices"], discardStderr: true)
        return parseAdbDeviceSerials(out)
    }

    /// Pure parse of `adb devices` output → the serials in the `device` state.
    /// Extracted so the tab-vs-whitespace handling (see above) is unit-testable
    /// without a device attached.
    static func parseAdbDeviceSerials(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2, cols.last == "device" else { return nil }
            return cols.first
        }
    }

    // MARK: - iOS

    private func deployIOS(pwa: PWAManifest, outputDir: URL) async throws {
        if simulator {
            try await deployIOSSimulator(pwa: pwa, outputDir: outputDir)
        } else {
            try await deployIOSDevice(pwa: pwa, outputDir: outputDir)
        }
    }

    // MARK: iOS simulator

    private func deployIOSSimulator(pwa: PWAManifest, outputDir: URL) async throws {
        if !noBuild { try await runBuild(crossCompileAndroid: false) }
        let app = outputDir.appendingPathComponent("\(pwa.name).app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw ValidationError("built simulator app not found at \(app.path) — run without --no-build.")
        }

        let udid = try await resolveSimulator()
        // Bring the Simulator UI up (a `simctl boot` alone doesn't open it).
        try? await Shell.run("/usr/bin/env", ["open", "-a", "Simulator"])
        print("→ installing to simulator \(udid)")
        try await Shell.run("/usr/bin/env", ["xcrun", "simctl", "install", udid, app.path])

        if launch {
            let bundleID = pwa.ios?.bundleIdentifier ?? pwa.id
            print("→ launching \(bundleID)")
            try await Shell.run("/usr/bin/env", ["xcrun", "simctl", "launch", udid, bundleID])
        }
        print("Deployed to simulator \(udid).")
    }

    // MARK: iOS device

    private func deployIOSDevice(pwa: PWAManifest, outputDir: URL) async throws {
        // Resolve the device first — fail fast before a (signed, minutes-long)
        // build if nothing's connected. The build then produces a signed .app
        // that `devicectl` installs.
        let target = try await IOSDeviceResolver.resolve(explicit: device)

        if !noBuild {
            if team == nil, sign == nil {
                // The build would fail with iosDeviceUnsigned anyway; a heads-up
                // here points at the shortest path before the compile.
                print(
                    "swift-pwa: note — an on-device install needs a signed build. Pass --team <TEAMID> "
                        + "(or --sign + --provisioning-profile + --entitlements). See docs/ios-setup.md."
                )
            }
            // Forward the resolved device so the free-team minter (in `build`)
            // registers this exact device when --allow-provisioning-registration
            // is set.
            try await runBuild(crossCompileAndroid: false, iosDeviceUDID: target.udid)
        }

        // The device build signs the .app in place (embedded profile) before
        // zipping the .ipa; `devicectl install app` wants the .app bundle.
        let app = outputDir.appendingPathComponent("\(pwa.name).app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw ValidationError("built app not found at \(app.path) — run without --no-build.")
        }

        print("→ installing to \(target.name) (\(target.udid))")
        try await Shell.run(
            "/usr/bin/env", ["xcrun", "devicectl", "device", "install", "app", "--device", target.udid, app.path]
        )

        if launch {
            let bundleID = pwa.ios?.bundleIdentifier ?? pwa.id
            print("→ launching \(bundleID)")
            do {
                try await Shell.run(
                    "/usr/bin/env",
                    [
                        "xcrun",
                        "devicectl",
                        "device",
                        "process",
                        "launch",
                        "--terminate-existing",
                        "--device",
                        target.udid,
                        bundleID
                    ]
                )
            } catch {
                // The app is installed; a first launch under a development /
                // free-team profile is refused until the developer is trusted on
                // the device. That's a one-time manual step deploy can't do — so
                // don't fail the whole deploy, just point at it.
                print("""
                swift-pwa: installed, but the launch was refused — a development/free-team app must \
                be trusted on the device once before it will run: Settings → General → VPN & Device \
                Management → (your Apple account) → Trust. Then tap the app, or re-run with --no-build.
                """)
            }
        }
        print("Deployed to \(target.name) (\(target.udid)).")
    }

    private struct SimDevice {
        let udid: String
        let name: String
        let state: String
    }

    /// Choose the simulator to target: an explicit `--device` (name or UDID,
    /// booted on demand), else a booted one, else the first available iOS
    /// simulator (booted on demand).
    private func resolveSimulator() async throws -> String {
        let devices = try await Self.listAvailableIOSSimulators()
        if let device {
            guard let match = devices.first(where: { $0.udid == device || $0.name == device }) else {
                throw ValidationError(
                    "no available iOS simulator matches --device \"\(device)\". "
                        + "List them with `xcrun simctl list devices available`."
                )
            }
            try await Self.bootIfNeeded(match)
            return match.udid
        }
        if let booted = devices.first(where: { $0.state == "Booted" }) {
            return booted.udid
        }
        guard let pick = devices.first else {
            throw ValidationError(
                "no iOS simulators are available. Install a runtime (Xcode → Settings → Platforms → iOS) and retry."
            )
        }
        try await Self.bootIfNeeded(pick)
        return pick.udid
    }

    private static func bootIfNeeded(_ device: SimDevice) async throws {
        guard device.state != "Booted" else { return }
        print("→ booting simulator \(device.name)")
        // `simctl boot` on an already-booted device errors; we guarded on state.
        try? await Shell.run("/usr/bin/env", ["xcrun", "simctl", "boot", device.udid])
    }

    private static func listAvailableIOSSimulators() async throws -> [SimDevice] {
        let json = try await Shell.capture(
            "/usr/bin/env", ["xcrun", "simctl", "list", "devices", "available", "-j"], discardStderr: true
        )
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let byRuntime = obj["devices"] as? [String: [[String: Any]]]
        else { return [] }
        var result: [SimDevice] = []
        for (runtime, list) in byRuntime where runtime.contains("iOS") {
            for entry in list {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                result.append(SimDevice(udid: udid, name: name, state: entry["state"] as? String ?? "Shutdown"))
            }
        }
        return result
    }

    // MARK: - macOS

    private func deployMac(pwa: PWAManifest, outputDir: URL) async throws {
        if !noBuild { try await runBuild(crossCompileAndroid: false) }
        let app = outputDir.appendingPathComponent("\(pwa.name).app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw ValidationError("built app not found at \(app.path) — run without --no-build.")
        }
        guard launch else {
            print("Built: \(app.path)")
            return
        }
        print("→ opening \(app.lastPathComponent)")
        try await Shell.run("/usr/bin/env", ["open", app.path])
        print("Deployed: \(app.path)")
    }

    // MARK: - Linux / Windows

    private func deployDesktopBinary(pwa: PWAManifest, projectRoot: URL, outputDir: URL) async throws {
        if !noBuild { try await runBuild(crossCompileAndroid: false) }
        guard let artifact = await Self.resolveDesktopArtifact(
            target: target, projectRoot: projectRoot, outputDir: outputDir, pwa: pwa
        ) else {
            // Don't guess wrong — point at the output dir and let the user run it.
            print(
                "Built into \(outputDir.path), but couldn't locate a single runnable artifact to launch. "
                    + "Run it from there."
            )
            return
        }
        guard launch else {
            print("Built: \(artifact.path)")
            return
        }
        print("→ running \(artifact.lastPathComponent) (Ctrl-C to stop)")
        try await Shell.run(artifact.path, [])
    }

    /// Best-effort locate the runnable artifact `build` produced for a desktop
    /// target. Linux: the newest `*.AppImage` in the output dir. Windows: the
    /// single-file `<exe>.exe` in the output dir, else the portable folder's
    /// `<name>/<exe>.exe`.
    private static func resolveDesktopArtifact(
        target: BuildTarget, projectRoot: URL, outputDir: URL, pwa: PWAManifest
    ) async -> URL? {
        let fm = FileManager.default
        switch target {
        case .linux:
            // Newest by modification date — a fresh `build` may leave an older
            // AppImage alongside the new one, and lexicographic order can pick
            // the wrong (stale) file when versions aren't zero-padded.
            let images = ((try? fm.contentsOfDirectory(atPath: outputDir.path)) ?? [])
                .filter { $0.hasSuffix(".AppImage") }
                .map { outputDir.appendingPathComponent($0) }
            return images.max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a < b
            }
        case .windows:
            let exe = await ExecutableNameResolver.resolve(projectRoot: projectRoot, manifest: pwa)
            let singleFile = outputDir.appendingPathComponent("\(exe).exe")
            if fm.fileExists(atPath: singleFile.path) { return singleFile }
            let inFolder = outputDir.appendingPathComponent(pwa.name).appendingPathComponent("\(exe).exe")
            if fm.fileExists(atPath: inFolder.path) { return inFolder }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Helpers

    /// Whether a tool resolves on PATH, by probing `<tool> --version`. Used for
    /// the `adb` gate; `Shell.capture` throws `toolMissing` when it can't be
    /// resolved, which we map to `false`.
    private static func toolOnPath(_ name: String) async -> Bool {
        await (try? Shell.capture(name, ["--version"], timeout: 10, discardStderr: true)) != nil
    }
}
