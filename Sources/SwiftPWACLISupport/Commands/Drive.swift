import ArgumentParser
import Foundation
import SwiftPWACore

/// Drives a running app over its opt-in control socket — evaluate JS in the
/// page, screenshot the webview, read window geometry — without taking over
/// the machine.
///
/// The gap this fills: Android apps have been scriptable since the CDP socket
/// landed, but on desktop `Cmd+Opt+J` / `Ctrl+Alt+J` opens DevTools for a
/// human and that's the whole story. The usual workaround — screen capture
/// plus OS-wide synthetic clicks — requires the app frontmost, photographs
/// whatever window drifted on top, and needs TCC grants no CI runner can click
/// through. Every verb here goes through the app's own renderer instead, so a
/// backgrounded, occluded window drives and screenshots correctly.
///
/// By default `drive` **owns the app's lifecycle**: it builds, launches with
/// `SWIFT_PWA_DRIVE=0`, reads the port and per-launch token off the app's
/// stdout, runs the verb, and tears the app down. Pass `--attach <port>
/// --token <token>` to talk to an app you launched yourself.
struct Drive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drive",
        abstract: "Drive and screenshot a running app over its control socket.",
        discussion: """
        Requires a driver-capable build: the control socket is compiled into debug builds only, so a \
        shipped release binary doesn't contain it at all (build with SWIFT_PWA_DRIVER=1 to override \
        that). Nothing listens until SWIFT_PWA_DRIVE names a port, and every frame carries a token \
        minted fresh at launch — `drive` handles all three for you.

        Native synthetic input (input.mouse / input.key) is not implemented yet on any backend; \
        drive the DOM through `eval` in the meantime. `drive info` reports what a given backend \
        actually supports.
        """,
        subcommands: [DriveEval.self, DriveShot.self, DriveWindows.self, DriveInfo.self]
    )
}

// MARK: - Shared options

struct DriveOptions: ParsableArguments {
    @Option(name: .long, help: "Path to pwa.json (used to resolve the executable). Defaults to ./pwa.json.")
    var manifest: String = "pwa.json"

    @Option(name: .long, help: "Build configuration to launch: debug (default) or release.")
    var configuration: String = "debug"

    @Option(name: .long, help: "Talk to an already-running app on this loopback port instead of launching one.")
    var attach: Int?

    @Option(name: .long, help: "The launch token the app printed. Required with --attach.")
    var token: String?

    @Option(name: .long, help: "Poll this JS expression until it's truthy before running the verb.")
    var wait: String?

    @Option(name: .long, help: "Seconds to wait for the app, the page, and --wait. Default 30.")
    var timeout: Double = 30

    @Option(name: .long, help: "Open the app's first window at this bundle path, e.g. /doc.html?id=42.")
    var route: String?

    @Option(name: .long, help: "Target window id (from `drive windows`). Defaults to the only open window.")
    var window: String?

    @Flag(help: "Don't wait for document.readyState === 'complete' before running the verb.")
    var noPageWait: Bool = false
}

// MARK: - Verbs

struct DriveEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Evaluate JavaScript in the page and print the JSON result."
    )

    @Argument(help: "The JavaScript to evaluate, e.g. \"document.title\".")
    var script: String

    @OptionGroup var options: DriveOptions

    func run() async throws {
        try await DriveSession.run(options) { client in
            var payload: [String: DriverJSON] = ["js": .string(script)]
            if let window = options.window { payload["window"] = .string(window) }
            try print(client.invoke("eval", payload).prettyPrinted)
        }
    }
}

struct DriveShot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shot",
        abstract: "Write a PNG of the webview's contents.",
        discussion: """
        The app's own pixels, not the screen's — the window can be behind other windows, on another \
        Space / workspace, or unfocused, and the capture is still of the app and only the app.
        """
    )

    @Argument(help: "Output .png path.")
    var output: String

    @OptionGroup var options: DriveOptions

    func run() async throws {
        try await DriveSession.run(options) { client in
            var payload: [String: DriverJSON] = [:]
            if let window = options.window { payload["window"] = .string(window) }
            let result = try client.invoke("screenshot", payload)
            guard let base64 = result["pngBase64"]?.stringValue,
                  let png = Data(base64Encoded: base64)
            else {
                throw DriveError.remote(code: "E_DRIVER", message: "the app returned no image data")
            }
            let url = URL(fileURLWithPath: output)
            try png.write(to: url)
            print("Wrote \(url.path) (\(png.count) bytes).")
        }
    }
}

struct DriveWindows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List the app's open windows with their ids and geometry."
    )

    @OptionGroup var options: DriveOptions

    func run() async throws {
        try await DriveSession.run(options) { client in
            try print(client.invoke("window.list").prettyPrinted)
        }
    }
}

struct DriveInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Report what this backend's driver actually supports."
    )

    @OptionGroup var options: DriveOptions

    func run() async throws {
        // Capabilities is the one verb that's meaningful before the page has
        // painted, so don't make the caller wait for a document.
        var options = options
        options.noPageWait = true
        try await DriveSession.run(options) { client in
            try print(client.invoke("capabilities").prettyPrinted)
        }
    }
}

// MARK: - Session lifecycle

enum DriveSession {
    /// Get a connected client into `body`'s hands, then clean up — launching
    /// and tearing down the app unless `--attach` says one is already running.
    static func run(_ options: DriveOptions, _ body: (DriverClient) throws -> Void) async throws {
        if let port = options.attach {
            guard let token = options.token else {
                throw ValidationError("--attach needs the --token the app printed at launch.")
            }
            let client = try DriverClient(port: UInt16(port), token: token)
            try prepare(client, options)
            try body(client)
            return
        }

        let app = try await LaunchedApp.build(options)
        defer { app.terminate() }
        let client = try DriverClient(port: app.port, token: app.token)
        try prepare(client, options)
        try body(client)
    }

    /// Both waits are client-side (see `DriverClient.wait`): a page-ready poll
    /// so `drive shot` doesn't photograph a blank window straight after launch,
    /// then the caller's own `--wait` expression.
    private static func prepare(_ client: DriverClient, _ options: DriveOptions) throws {
        if !options.noPageWait {
            // `location.href !== 'about:blank'` is load-bearing, not belt and
            // braces: a window's content is loaded from a task scheduled onto
            // the UI thread, so the driver can connect and eval while the
            // webview is still sitting on its initial empty document — which
            // reports `readyState === 'complete'` perfectly happily.
            try client.wait(
                for: "document.readyState === 'complete' && location.href !== 'about:blank'",
                timeout: options.timeout,
                window: options.window
            )
        }
        if let expression = options.wait {
            try client.wait(for: expression, timeout: options.timeout, window: options.window)
        }
    }
}

/// An app process `drive` started and owns.
struct LaunchedApp {
    let process: Process
    let port: UInt16
    let token: String

    /// Build the app, launch it with the driver env var set, and wait for it to
    /// announce its port and token on stdout.
    ///
    /// Builds and launches as two steps rather than one `swift run`: the app has
    /// to be a direct child so terminating it actually terminates it, and it
    /// keeps compiler output from interleaving with the handshake line.
    static func build(_ options: DriveOptions) async throws -> LaunchedApp {
        guard ["debug", "release"].contains(options.configuration) else {
            throw ValidationError("--configuration must be 'debug' or 'release', got '\(options.configuration)'.")
        }
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let manifestURL = cwd.appendingPathComponent(options.manifest)
        let pwa: PWAManifest
        do {
            pwa = try PWAManifest.load(from: manifestURL)
        } catch {
            throw ValidationError(
                "Couldn't read \(manifestURL.path): \(error). Run `swift-pwa drive` from your app's directory."
            )
        }
        let exe = await ExecutableNameResolver.resolve(projectRoot: cwd, manifest: pwa)

        print("Building \(exe) (\(options.configuration))…")
        try await Shell.run(
            "/usr/bin/env",
            ["swift", "build", "-c", options.configuration, "--product", exe],
            cwd: cwd
        )
        let binPath = try await Shell.capture(
            "/usr/bin/env",
            ["swift", "build", "-c", options.configuration, "--show-bin-path"],
            cwd: cwd
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        var executable = URL(fileURLWithPath: binPath).appendingPathComponent(exe)
        #if os(Windows)
            executable = executable.appendingPathExtension("exe")
        #endif
        guard fm.fileExists(atPath: executable.path) else {
            throw DriveError.launch("built \(exe) but found no executable at \(executable.path)")
        }

        return try launch(
            executable: executable,
            cwd: cwd,
            timeout: options.timeout,
            route: options.route
        )
    }

    private static func launch(
        executable: URL,
        cwd: URL,
        timeout: TimeInterval,
        route: String?
    ) throws -> LaunchedApp {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        // 0 = let the OS pick a free port, which it then tells us about.
        env[AppDriver.environmentVariable] = "0"
        // Land on a specific screen without navigating there by hand — and
        // without the usual hack of patching `location.replace` into the built
        // bundle, which mutates the artifact under test.
        if let route { env[InitialRoute.environmentVariable] = route }
        process.environment = env

        let stdout = Pipe()
        process.standardOutput = stdout
        // The app's stderr passes straight through: its diagnostics are the
        // main clue when a driven run misbehaves.
        process.standardError = FileHandle.standardError

        let handshake = HandshakeReader()
        // The app's stdout has to keep being drained for the whole session —
        // a full pipe buffer would block the app mid-run — so the reader
        // thread forwards everything to our stderr after the handshake.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            handshake.consume(data)
        }

        try process.run()

        guard let announcement = handshake.wait(seconds: min(timeout, 60)) else {
            process.terminate()
            throw DriveError.launch("""
            the app started but never announced a driver port.

            The control socket is compiled into debug builds only. If this was a release build, either
            drive the debug build instead (drop --configuration release) or rebuild with
              SWIFT_PWA_DRIVER=1 swift build -c release
            """)
        }
        return LaunchedApp(process: process, port: announcement.port, token: announcement.token)
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        // Give the app a moment to close its window cleanly rather than
        // leaving a zombie behind on the user's desktop.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

/// Scans the app's stdout for the driver's announcement line, then keeps
/// draining so a chatty app can't fill the pipe and stall.
private final class HandshakeReader: @unchecked Sendable {
    struct Announcement {
        let port: UInt16
        let token: String
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var announcement: Announcement?
    private var pending = ""

    func consume(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        pending += text
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast() // keep the partial tail
        let found = announcement == nil ? lines.compactMap(Self.parse).first : nil
        if let found {
            announcement = found
        }
        lock.unlock()

        // Echo to stderr, not stdout: the CLI's own stdout carries the verb's
        // result, which a caller may well be piping into `jq`.
        FileHandle.standardError.writeQuietly(Data(
            lines.filter { Self.parse($0) == nil }
                .map { $0 + "\n" }.joined().utf8
        ))
        if found != nil { semaphore.signal() }
    }

    func wait(seconds: TimeInterval) -> Announcement? {
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return announcement
    }

    /// Parses `swift-pwa driver listening port=51234 token=<hex>`.
    private static func parse(_ line: String) -> Announcement? {
        guard line.hasPrefix("swift-pwa driver listening ") else { return nil }
        var port: UInt16?
        var token: String?
        for field in line.split(separator: " ") {
            if field.hasPrefix("port=") { port = UInt16(field.dropFirst(5)) }
            if field.hasPrefix("token=") { token = String(field.dropFirst(6)) }
        }
        guard let port, let token else { return nil }
        return Announcement(port: port, token: token)
    }
}

// MARK: - Errors

enum DriveError: Error, CustomStringConvertible {
    case connect(String)
    case launch(String)
    case remote(code: String, message: String)
    case timedOut(expression: String, seconds: TimeInterval, lastError: String?)

    var description: String {
        switch self {
        case let .connect(message): "couldn't reach the app's driver: \(message)"
        case let .launch(message): "couldn't launch the app: \(message)"
        case let .remote(code, message): "\(code): \(message)"
        case let .timedOut(expression, seconds, lastError):
            if let lastError {
                "timed out after \(Int(seconds))s waiting for `\(expression)` (last error: \(lastError))"
            } else {
                "timed out after \(Int(seconds))s waiting for `\(expression)` to become truthy"
            }
        }
    }
}
