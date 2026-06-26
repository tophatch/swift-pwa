import ArgumentParser
import Foundation

struct Dev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Run the app against a live-reloading dev server.",
        discussion: """
        With no --server, swift-pwa serves your web/ directory itself, injects a live-reload \
        client, and refreshes the app whenever a file changes — no JS framework or external \
        server needed. Pass --server <url> to point at your own dev server instead (e.g. Vite's \
        http://localhost:5173), which keeps its own hot-reload. Either way the app is launched \
        with PWA_DEV_SERVER set, so the generated App.swift loads the dev URL instead of the \
        bundled assets.
        """
    )

    @Option(help: "Point at your own dev server URL instead of swift-pwa's built-in live-reload server.")
    var server: String?

    @Option(help: "Path to pwa.json (used to locate web/). Defaults to ./pwa.json.")
    var manifest: String = "pwa.json"

    @Option(
        help: """
        Port for the built-in live-reload server. A fixed port (default \(Dev.defaultPort)) keeps a \
        stable origin across launches, so OPFS / localStorage / IndexedDB persist between runs. \
        Pass 0 for an OS-assigned port (storage resets each launch). Ignored with --server.
        """
    )
    var port: UInt16 = Dev.defaultPort

    /// Default loopback port for the built-in dev server. Fixed (not
    /// OS-assigned) so the dev origin — and therefore per-origin web storage
    /// — is stable across `swift-pwa dev` launches.
    static let defaultPort: UInt16 = 4321

    func run() async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let devURL: String
        if let server {
            // External dev server (Vite, etc.) — use it as-is.
            devURL = server
        } else {
            #if canImport(Darwin) || canImport(Glibc)
                // Built-in live-reload server over the project's web/ dir.
                let pwa = try PWAManifest.load(from: cwd.appendingPathComponent(manifest))
                let webDir = cwd.appendingPathComponent(pwa.web.directory)
                guard FileManager.default.fileExists(atPath: webDir.path) else {
                    throw ValidationError(
                        "No \(pwa.web.directory)/ directory at \(cwd.path). Run `swift-pwa dev` from your project root, "
                            + "or pass --server <url> to use your own dev server."
                    )
                }
                let dev = DevServer(root: webDir, entry: pwa.web.entry, port: port)
                let url = try dev.start()
                let persistenceNote = port == 0
                    ? " (OS-assigned port — web storage resets each launch; use a fixed --port to persist it)"
                    : ""
                print(
                    "Live-reload server serving \(pwa.web.directory)/ at \(url.absoluteString) — edit and save to refresh."
                        + persistenceNote
                )
                devURL = url.absoluteString
            #else
                throw ValidationError(
                    "The built-in live-reload server isn't available on this host yet. "
                        + "Pass --server <url> to point at your own dev server (e.g. http://localhost:5173)."
                )
            #endif
        }

        let task = Process()
        task.executableURL = try Bash.which("swift")
        task.arguments = ["run"]
        var env = ProcessInfo.processInfo.environment
        env["PWA_DEV_SERVER"] = devURL
        task.environment = env
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw ExitCode(task.terminationStatus)
        }
    }
}

enum Bash {
    static func which(_ name: String) throws -> URL {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            throw ValidationError("Could not find executable: \(name)")
        }
        return URL(fileURLWithPath: path)
    }
}
