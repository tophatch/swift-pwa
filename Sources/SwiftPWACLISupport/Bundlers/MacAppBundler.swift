import ArgumentParser
import Foundation

/// Builds a macOS `.app` from a `swift-pwa` project. The flow:
///   1. `swift build -c <configuration>` (with `--arch` per requested slice) to
///      produce the binary.
///   2. Lay out `MyApp.app/Contents/{MacOS,Resources}`.
///   3. Generate `Info.plist` from the manifest.
///   4. Copy the web bundle into `Contents/Resources/web`.
///   5. Convert the icon (PNG → .icns) via `sips`/`iconutil` if present.
///   6. Optionally codesign with the supplied identity.
struct MacAppBundler {
    let manifest: PWAManifest
    let projectRoot: URL
    let outputDir: URL
    let signIdentity: String?
    let entitlements: URL?
    /// `notarytool` keychain profile name. When set, the signed `.app` is
    /// submitted to Apple's notary service and the ticket stapled to it,
    /// fully automating submit → wait → staple. nil skips notarization.
    var notarizeProfile: String?
    /// Architecture slices to build. Empty = the host's, SwiftPM's default. Two
    /// or more produce one universal (fat) binary in a single `swift build`.
    var archs: [String] = []
    var configuration: BuildConfiguration = .release

    func build() async throws -> URL {
        // 1. swift build. `--arch` is repeatable and SwiftPM lipos the slices
        // itself; with more than one it also moves the products to
        // `.build/apple/Products/<Config>`, so ask it where they landed rather
        // than assuming `.build/<config>`.
        let buildArgs = ["swift", "build", "-c", configuration.swiftPMValue]
            + archs.flatMap { ["--arch", $0] }
        try await Shell.run("/usr/bin/env", buildArgs, cwd: projectRoot)
        let binDir = try await URL(fileURLWithPath: Shell.capture(
            "/usr/bin/env", buildArgs + ["--show-bin-path"], cwd: projectRoot
        ).trimmingCharacters(in: .whitespacesAndNewlines))
        // The built binary is named after the SwiftPM target — resolved
        // from the package itself (via `swift package describe`), which
        // may differ from the human-facing display `name` used for the
        // `.app` filename / CFBundleName.
        let exe = await ExecutableNameResolver.resolve(projectRoot: projectRoot, manifest: manifest)
        let binary = binDir.appendingPathComponent(exe)
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw BundlerError.binaryMissing(binary, expectedName: exe)
        }

        // 2. .app skeleton — the bundle filename is the display `name`
        // (spaces allowed: "Field Notes.app"), the executable inside it
        // is `exe` (the SwiftPM target).
        let app = outputDir.appendingPathComponent("\(manifest.name).app")
        if FileManager.default.fileExists(atPath: app.path) {
            try FileManager.default.removeItem(at: app)
        }
        let macOSDir = app.appendingPathComponent("Contents/MacOS")
        let resourcesDir = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: macOSDir.appendingPathComponent(exe))
        if archs.count > 1 { await Self.reportSlices(of: binary) }

        // Any SwiftPM resource bundles the build produced (an adopter target or
        // a dependency declaring `resources:`). swift-pwa's own runtime makes
        // none — see ResourceBundles for why `Contents/Resources` is the only
        // place they can go, and what that costs.
        try ResourceBundles.reportAppBundleCaveat(
            ResourceBundles.stage(ResourceBundles.found(in: binDir), into: resourcesDir)
        )

        // 3. Info.plist
        let plist = InfoPlistGenerator.macOS(manifest: manifest, executableName: exe)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))

        // PkgInfo
        try "APPL????".write(
            to: app.appendingPathComponent("Contents/PkgInfo"),
            atomically: true,
            encoding: .ascii
        )

        // 4. Web bundle
        let webSrc = projectRoot.appendingPathComponent(manifest.web.directory)
        let webDst = resourcesDir.appendingPathComponent("web")
        if FileManager.default.fileExists(atPath: webSrc.path) {
            try FileManager.default.copyItem(at: webSrc, to: webDst)
        }

        // 5. Icon (best-effort: a missing tool or file never fails the build).
        await IconOutcome.report(bundleIcon(into: resourcesDir))

        // 6. Credits.html for the standard About panel — shown below
        // the version + copyright. AppKit picks this up automatically.
        if let description = manifest.description, !description.isEmpty {
            try Self.creditsHTML(description: description).write(
                to: resourcesDir.appendingPathComponent("Credits.html"),
                atomically: true,
                encoding: .utf8
            )
        }

        // 7. Codesign
        if let identity = signIdentity {
            var args = ["codesign", "--force", "--sign", identity]
            if let ent = entitlements {
                args.append(contentsOf: ["--entitlements", ent.path])
            }
            // Notarization requires a hardened-runtime signature.
            if notarizeProfile != nil {
                args.append(contentsOf: ["--options", "runtime", "--timestamp"])
            }
            args.append(app.path)
            try await Shell.run("/usr/bin/env", args)
        } else {
            print("note: not signed. Pass --sign <identity> for a signed build.")
            print("      For notarization, also pass --notarize <keychain-profile>.")
        }

        // 8. Notarize + staple (opt-in, macOS distribution).
        if let profile = notarizeProfile {
            try await notarize(app: app, profile: profile)
        }

        return app
    }

    /// Print the slices actually present in a multi-arch build, read back from
    /// the binary rather than echoed from the flags — the point of asking for
    /// two architectures is that both are really there. Best-effort: a missing
    /// `lipo` says nothing rather than failing the build.
    private static func reportSlices(of binary: URL) async {
        guard let out = try? await Shell.capture(
            "/usr/bin/env", ["lipo", "-archs", binary.path], discardStderr: true
        ) else { return }
        let slices = out.split(whereSeparator: \.isWhitespace).joined(separator: ", ")
        guard !slices.isEmpty else { return }
        print("swift-pwa: universal binary — \(slices)")
    }

    /// Convert `manifest.icon` (a PNG) into `AppIcon.icns` via
    /// `sips`/`iconutil`. Best-effort: reports (never throws) so a missing
    /// tool or file leaves the app with the system default rather than
    /// failing the build.
    private func bundleIcon(into resourcesDir: URL) async -> IconOutcome {
        guard let icon = manifest.icon else { return .noneSet }
        let iconURL = projectRoot.appendingPathComponent(icon)
        guard FileManager.default.fileExists(atPath: iconURL.path) else {
            return .notFound(source: icon, placeholder: false)
        }
        guard iconURL.pathExtension.lowercased() == "png" else {
            return .notPNG(source: icon, placeholder: false)
        }
        do {
            let sizes = try await IconConverter.makeICNS(
                from: iconURL,
                into: resourcesDir.appendingPathComponent("AppIcon.icns"),
                // Persist the rendered .icns across rebuilds (keyed by the
                // source PNG + CLI version) so an unchanged icon skips the
                // sips/iconutil pipeline. `.build` is git-ignored and dropped
                // by `swift package clean`.
                cacheDir: projectRoot.appendingPathComponent(".build/swift-pwa/icon-cache")
            )
            return .bundled(source: icon, detail: "\(sizes) sizes")
        } catch {
            return .toolFailed(source: icon, reason: "sips/iconutil unavailable")
        }
    }

    /// Submit the signed `.app` to Apple's notary service and staple the
    /// resulting ticket — the submit → wait → staple loop the bundler used
    /// to only *print*. Requires a code-signing identity (the app must be
    /// Developer ID-signed with a hardened runtime first) and a
    /// `notarytool` keychain profile created once via
    /// `xcrun notarytool store-credentials`.
    private func notarize(app: URL, profile: String) async throws {
        guard signIdentity != nil else {
            throw BundlerError.notarizeUnsigned
        }
        // notarytool takes a zip/pkg/dmg, not a bare .app — zip with ditto
        // so the bundle layout (symlinks) survives the round-trip.
        let zip = app.deletingPathExtension().appendingPathExtension("zip")
        if FileManager.default.fileExists(atPath: zip.path) {
            try FileManager.default.removeItem(at: zip)
        }
        try await Shell.run("/usr/bin/env", [
            "ditto", "-c", "-k", "--keepParent", app.path, zip.path
        ])
        print("Submitting to Apple's notary service (this can take a few minutes)…")
        // `--wait` blocks until Apple finishes; a rejected submission exits
        // non-zero, which propagates as a build failure.
        try await Shell.run("/usr/bin/env", [
            "xcrun", "notarytool", "submit", zip.path,
            "--keychain-profile", profile, "--wait"
        ])
        // Staple the ticket onto the .app so it validates offline.
        try await Shell.run("/usr/bin/env", ["xcrun", "stapler", "staple", app.path])
        try? FileManager.default.removeItem(at: zip)
        print("Notarized and stapled: \(app.path)")
    }

    private static func creditsHTML(description: String) -> String {
        // Tiny, no external CSS — the About panel renders this in a
        // small fixed-size text view so we just need the body text
        // with HTML-escaped content and minimal styling.
        let escaped = description
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8" /><style>
        body { font: -apple-system-body; color: -apple-system-text; margin: 8px; }
        </style></head><body>\(escaped)</body></html>
        """
    }
}

enum BundlerError: Error, CustomStringConvertible {
    case binaryMissing(URL, expectedName: String)
    case toolMissing(String)
    case shell(Int32, String)
    case timedOut(String, seconds: TimeInterval)
    case iosSimulatorRuntimeMissing
    case notarizeUnsigned
    case iosDeviceUnsigned
    case profileMintFailed(bundleID: String, team: String)

    var description: String {
        switch self {
        case .iosDeviceUnsigned:
            """
            An iOS device build needs code signing — without it the .ipa installs but won't launch \
            ("invalid code signature, inadequate entitlements or its profile has not been explicitly \
            trusted"). Pass --sign "Apple Development: …", and for an on-device install also \
            --provisioning-profile <p.mobileprovision> --entitlements <e.plist> (the profile must list \
            the device's UDID). See docs/ios-setup.md. (For a simulator build, use --simulator instead.)
            """
        case .notarizeUnsigned:
            """
            --notarize requires a signed app. Pass --sign "Developer ID Application: …" too.
            Apple's notary service only accepts Developer ID-signed apps with a hardened runtime.
            """
        case let .binaryMissing(url, name):
            // The bundler resolves the executable name from the package
            // (`swift package describe`) or an explicit `executable_name`,
            // so reaching here means the build didn't actually produce
            // that product — point at the likely causes.
            """
            expected built binary at \(url.path)
            The build ran but produced no executable named '\(name)'. Likely causes: the build \
            didn't finish producing the executable product, or pwa.json's `executable_name` names \
            a SwiftPM target that doesn't exist in Package.swift. If `executable_name` is set, make \
            it match a target name there (or remove it to let swift-pwa read the name from the package).
            """
        case let .toolMissing(name): "required tool not on PATH: \(name)"
        case let .shell(code, cmd): "command failed (\(code)): \(cmd)"
        case let .timedOut(cmd, seconds):
            """
            timed out after \(Int(seconds))s (and was terminated): \(cmd)
            It produced no result and didn't exit — that's a wedged tool, not a slow one. \
            `simctl` does this on a cold machine; `xcrun simctl shutdown all` usually clears it.
            """
        case let .profileMintFailed(bundleID, team):
            """
            --allow-provisioning-registration: the throwaway build for team \(team) / bundle id \
            \(bundleID) finished but produced no embedded.mobileprovision. Common causes: the target \
            device wasn't reachable to register, the Apple ID needs its free-team agreement accepted \
            in Xcode once, or the bundle id is already taken by another team. Try building any app to \
            the device from Xcode once to clear the first-run consent, then retry. See docs/ios-setup.md.
            """
        case .iosSimulatorRuntimeMissing:
            """
            no iOS Simulator runtime installed.
            Install one with: xcodebuild -downloadPlatform iOS
            or via: Xcode → Settings → Platforms → iOS → +
            """
        }
    }
}

enum Shell {
    /// Run a long-lived command with stdio inherited from the parent.
    /// Used for `swift build`, `xcodebuild`, `linuxdeploy`, etc. so the
    /// user sees compile progress as it happens (otherwise a long
    /// release build looks like the CLI has hung).
    ///
    /// `envOverrides` are merged on top of the inherited process
    /// environment — pass overrides keyed by the env var name and we
    /// apply them with case-insensitive collision detection (`INCLUDE`
    /// wins over a pre-existing `Include`, etc.). Pass `nil` to inherit
    /// the parent env unchanged.
    /// `stdoutTo` redirects the child's stdout, which normally passes straight
    /// through to ours. The MCP server needs it: its own stdout carries the
    /// protocol stream, and a stray line of compiler progress there would
    /// corrupt the session.
    ///
    /// `timeout` (seconds) bounds the run: past the deadline the child is
    /// terminated and the call throws `BundlerError.timedOut`. Use it for any
    /// command that can wedge rather than fail — `simctl` is the reason it
    /// exists. A cold `simctl boot` on a CI runner sat for 39 minutes with no
    /// output and no exit, and an unbounded `waitUntilExit` turns that into a
    /// job that looks like a slow build instead of a stuck one.
    static func run(
        _ executable: String, _ arguments: [String],
        cwd: URL? = nil, envOverrides: [String: String]? = nil,
        stdoutTo: FileHandle? = nil, timeout: TimeInterval? = nil
    ) async throws {
        let task = Process()
        task.executableURL = try resolveExecutable(executable)
        task.arguments = arguments
        if let stdoutTo { task.standardOutput = stdoutTo }
        if let cwd { task.currentDirectoryURL = cwd }
        if let envOverrides {
            task.environment = mergeEnv(envOverrides)
        }
        // Inherit stdout/stderr — pass through to the user.
        try task.run()
        let timedOut = TimeoutFlag()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if task.isRunning {
                    timedOut.set()
                    task.terminate()
                }
            }
        }
        task.waitUntilExit()
        if timedOut.isSet, let timeout {
            throw BundlerError.timedOut(([executable] + arguments).joined(separator: " "), seconds: timeout)
        }
        if task.terminationStatus != 0 {
            throw BundlerError.shell(
                task.terminationStatus,
                ([executable] + arguments).joined(separator: " ")
            )
        }
    }

    /// One-bit box so the timeout timer and the waiting thread can agree on
    /// *why* a process ended, without either capturing the other's state.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    /// Merge `overrides` on top of the inherited process environment.
    /// Case-insensitive: an override of `INCLUDE` displaces any of
    /// `Include` / `include` already in the parent env. Necessary on
    /// Windows where env var names are case-insensitive at the OS
    /// level but Foundation surfaces them with the source's case.
    private static func mergeEnv(_ overrides: [String: String]) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            if let existingKey = merged.first(where: {
                $0.key.caseInsensitiveCompare(key) == .orderedSame
            })?.key {
                merged.removeValue(forKey: existingKey)
            }
            merged[key] = value
        }
        return merged
    }

    /// Run a short command and capture its stdout. Used for `which` and
    /// `swift package describe`.
    ///
    /// `timeout` (seconds) bounds the run: if the process is still alive
    /// after the deadline it's terminated and the call throws. Used by
    /// `doctor`, whose whole job is probing toolchains that might be
    /// wedged (e.g. an `xcrun` stuck on Xcode first-launch) — a probe must
    /// never hang the checker.
    static func capture(
        _ executable: String, _ arguments: [String],
        cwd: URL? = nil, timeout: TimeInterval? = nil, discardStderr: Bool = false
    ) async throws -> String {
        let task = Process()
        task.executableURL = try resolveExecutable(executable)
        task.arguments = arguments
        if let cwd { task.currentDirectoryURL = cwd }
        let stdout = Pipe()
        task.standardOutput = stdout
        // Surface a tool's own diagnostics by default; `doctor` discards
        // them (it only wants the probe's success / stdout, not noisy
        // banners from a half-configured toolchain).
        task.standardError = discardStderr ? FileHandle.nullDevice : FileHandle.standardError
        try task.run()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if task.isRunning { task.terminate() }
            }
        }
        task.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        if task.terminationStatus != 0 {
            throw BundlerError.shell(
                task.terminationStatus,
                ([executable] + arguments).joined(separator: " ")
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Resolve an executable name to an absolute URL.
    ///
    /// Foundation's `Process` on Apple is happy to take a bare
    /// command name and let the OS PATH-search; on
    /// swift-corelibs-foundation under Windows, `executableURL` is
    /// resolved literally — `URL(fileURLWithPath: "swift")` becomes
    /// `./swift`, which doesn't exist, and `Process.run()` throws
    /// `NSCocoaError 260` with `WindowsError 2` underneath. We do
    /// the PATH search ourselves so a bare `Shell.run("swift", …)`
    /// works the same on every host.
    ///
    /// Inputs that already contain a separator (`/usr/bin/env`,
    /// `C:\Path\To\tool.exe`) are passed through verbatim.
    private static func resolveExecutable(_ name: String) throws -> URL {
        if name.contains("/") || name.contains("\\") {
            return URL(fileURLWithPath: name)
        }
        #if os(Windows)
            let pathSeparator: Character = ";"
            let dirSeparator = "\\"
            // `where.exe` resolution order: empty (verbatim, in case
            // the caller passed `tool.exe`), then PATHEXT-style
            // suffixes. We don't read PATHEXT itself — sticking to
            // the four common executable suffixes covers swift /
            // makeappx / signtool / nuget without surprises.
            let suffixes = ["", ".exe", ".cmd", ".bat"]
        #else
            let pathSeparator: Character = ":"
            let dirSeparator = "/"
            let suffixes = [""]
        #endif
        // We test with `fileExists(atPath:)` rather than
        // `isExecutableFile(atPath:)` because the latter checks the
        // POSIX executable bit, which doesn't exist on NTFS — every
        // `.exe` on a Windows host returns false, defeating the
        // search. Joining the strings with the host separator (rather
        // than `URL.appendingPathComponent`) keeps the resulting path
        // entirely in native form so swift-corelibs-foundation
        // doesn't drop a `/` in front of `C:\…` and confuse `_stat`.
        //
        // PATH lookup is case-insensitive: Windows environment
        // variables are case-insensitive at the OS level but
        // swift-corelibs-foundation surfaces them with whatever case
        // the source set. PowerShell exports `Path`, cmd.exe exports
        // `PATH`, the swift-build environment can be either — so a
        // hard-coded `env["PATH"]` lookup misses on PowerShell-launched
        // sessions and the search comes up empty.
        let env = ProcessInfo.processInfo.environment
        let path = env.first(where: { $0.key.caseInsensitiveCompare("PATH") == .orderedSame })?.value ?? ""
        for dir in path.split(separator: pathSeparator, omittingEmptySubsequences: true) {
            for suffix in suffixes {
                let candidate = String(dir) + dirSeparator + name + suffix
                if FileManager.default.fileExists(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        throw BundlerError.toolMissing(name)
    }
}
