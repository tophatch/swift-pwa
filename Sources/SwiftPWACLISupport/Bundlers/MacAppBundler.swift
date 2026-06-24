import ArgumentParser
import Foundation

/// Builds a macOS `.app` from a `swift-pwa` project. The flow:
///   1. `swift build -c release` to produce the binary.
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

    func build() async throws -> URL {
        // 1. swift build -c release
        try await Shell.run(
            "/usr/bin/env",
            ["swift", "build", "-c", "release"],
            cwd: projectRoot
        )
        let binDir = projectRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("release")
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

        // 5. Icon (best-effort: skip silently if tools missing).
        if let icon = manifest.icon {
            let iconURL = projectRoot.appendingPathComponent(icon)
            if FileManager.default.fileExists(atPath: iconURL.path) {
                try? await IconConverter.makeICNS(
                    from: iconURL,
                    into: resourcesDir.appendingPathComponent("AppIcon.icns")
                )
            }
        }

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
            args.append(app.path)
            try await Shell.run("/usr/bin/env", args)
        } else {
            print("note: not signed. Pass --sign <identity> for a signed build.")
            print("      For notarization, run: xcrun notarytool submit \(app.path) --keychain-profile <profile>")
        }

        return app
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
    case iosSimulatorRuntimeMissing

    var description: String {
        switch self {
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
    static func run(
        _ executable: String, _ arguments: [String],
        cwd: URL? = nil, envOverrides: [String: String]? = nil
    ) async throws {
        let task = Process()
        task.executableURL = try resolveExecutable(executable)
        task.arguments = arguments
        if let cwd { task.currentDirectoryURL = cwd }
        if let envOverrides {
            task.environment = mergeEnv(envOverrides)
        }
        // Inherit stdout/stderr — pass through to the user.
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw BundlerError.shell(
                task.terminationStatus,
                ([executable] + arguments).joined(separator: " ")
            )
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
    static func capture(
        _ executable: String, _ arguments: [String], cwd: URL? = nil
    ) async throws -> String {
        let task = Process()
        task.executableURL = try resolveExecutable(executable)
        task.arguments = arguments
        if let cwd { task.currentDirectoryURL = cwd }
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.standardError // surface errors
        try task.run()
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
