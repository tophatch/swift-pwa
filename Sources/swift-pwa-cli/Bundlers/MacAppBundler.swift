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
        let binary = binDir.appendingPathComponent(manifest.name)
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw BundlerError.binaryMissing(binary)
        }

        // 2. .app skeleton
        let app = outputDir.appendingPathComponent("\(manifest.name).app")
        if FileManager.default.fileExists(atPath: app.path) {
            try FileManager.default.removeItem(at: app)
        }
        let macOSDir = app.appendingPathComponent("Contents/MacOS")
        let resourcesDir = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: macOSDir.appendingPathComponent(manifest.name))

        // 3. Info.plist
        let plist = InfoPlistGenerator.macOS(manifest: manifest)
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
    case binaryMissing(URL)
    case toolMissing(String)
    case shell(Int32, String)

    var description: String {
        switch self {
        case let .binaryMissing(url): "expected built binary at \(url.path)"
        case let .toolMissing(name): "required tool not on PATH: \(name)"
        case let .shell(code, cmd): "command failed (\(code)): \(cmd)"
        }
    }
}

enum Shell {
    /// Run a long-lived command with stdio inherited from the parent.
    /// Used for `swift build`, `xcodebuild`, `linuxdeploy`, etc. so the
    /// user sees compile progress as it happens (otherwise a long
    /// release build looks like the CLI has hung).
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let cwd { task.currentDirectoryURL = cwd }
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

    /// Run a short command and capture its stdout. Used for `which`.
    static func capture(_ executable: String, _ arguments: [String]) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
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
}
