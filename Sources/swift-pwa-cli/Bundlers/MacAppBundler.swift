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

        // 6. Codesign
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
}

enum BundlerError: Error, CustomStringConvertible {
    case binaryMissing(URL)
    case toolMissing(String)
    case shell(Int32, String)

    var description: String {
        switch self {
        case .binaryMissing(let url): return "expected built binary at \(url.path)"
        case .toolMissing(let name): return "required tool not on PATH: \(name)"
        case .shell(let code, let cmd): return "command failed (\(code)): \(cmd)"
        }
    }
}

enum Shell {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        if let cwd { task.currentDirectoryURL = cwd }
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        try task.run()
        task.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        if task.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let combined = (String(data: outData, encoding: .utf8) ?? "")
                + (String(data: errData, encoding: .utf8) ?? "")
            throw BundlerError.shell(
                task.terminationStatus,
                ([executable] + arguments).joined(separator: " ") + "\n" + combined
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
