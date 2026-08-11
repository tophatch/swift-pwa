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

        Synthetic input goes into the app's own event queue, so the page sees trusted events \
        without the real cursor moving and without the app needing to be frontmost. Not every \
        backend can do it — `drive info` reports what the one in front of you actually supports, \
        and a request it can't honour is refused rather than quietly downgraded.
        """,
        subcommands: [
            DriveEval.self, DriveShot.self, DriveClick.self, DriveType.self,
            DriveScroll.self, DriveWindows.self, DriveInfo.self
        ]
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

    /// 60, not 30: on a software-rendered headless Linux box the *first* WebKit
    /// start after a clean build can take longer than 30s, and the timeout that
    /// followed was indistinguishable from a broken page — it cost real time
    /// chasing a rendering bug that wasn't there. A too-low default fails runs
    /// that would have worked; a higher one only costs waiting on runs that are
    /// already broken, and `--timeout` overrides either way.
    @Option(name: .long, help: "Seconds to wait for the app, the page, and --wait. Default 60.")
    var timeout: Double = 60

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
            var payload: [String: BridgeJSON] = ["js": .string(script)]
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
            var payload: [String: BridgeJSON] = [:]
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

struct DriveClick: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click in the page — by CSS selector, viewport fraction, or CSS pixels.",
        discussion: """
        The click goes into the app's own event queue, so the page receives a trusted pointer \
        event, the real cursor never moves, and the window can stay in the background.

        Prefer --selector: it survives a layout change, which a hardcoded coordinate doesn't.
        """
    )

    @Argument(help: "x coordinate (CSS pixels, or 0-1 with --fraction). Omit when using --selector.")
    var x: Double?

    @Argument(help: "y coordinate.")
    var y: Double?

    @Option(name: .long, help: "Click the centre of the first element matching this CSS selector.")
    var selector: String?

    @Flag(help: "Treat x and y as fractions of the viewport (0-1) rather than CSS pixels.")
    var fraction: Bool = false

    @Option(name: .long, help: "Which button: left (default), right, middle, barrel or eraser.")
    var button: String = "left"

    @Option(name: .long, help: "Click count — 2 for a double-click.")
    var count: Int = 1

    @Option(name: .long, help: "Pointer type: mouse (default), pen or touch. Refused if the backend can't produce it.")
    var pointerType: String = "mouse"

    @OptionGroup var options: DriveOptions

    func run() async throws {
        try await DriveSession.run(options) { client in
            let point = try resolvePoint(client)
            for phase in ["down", "up"] {
                var payload: [String: BridgeJSON] = [
                    "type": .string(phase),
                    "x": .number(point.x),
                    "y": .number(point.y),
                    "button": .string(button),
                    "clickCount": .number(Double(count)),
                    "pointerType": .string(pointerType)
                ]
                if let window = options.window { payload["window"] = .string(window) }
                try client.invoke("input.pointer", payload)
            }
            print("Clicked at \(Int(point.x)), \(Int(point.y)).")
        }
    }

    private func resolvePoint(_ client: DriverClient) throws -> (x: Double, y: Double) {
        if let selector {
            return try client.center(of: selector, window: options.window)
        }
        guard let x, let y else {
            throw ValidationError("Give x and y coordinates, or --selector <css>.")
        }
        guard fraction else { return (x, y) }
        let viewport = try client.viewportSize(window: options.window)
        return (x * viewport.width, y * viewport.height)
    }
}

struct DriveType: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into the focused element, one key event per character.",
        discussion: """
        Real key events through the app's event queue, so text lands in whatever has focus and \
        input handlers fire — unlike setting `.value` from `eval`, which skips both.

        Focus something first (`drive click --selector "input#search"`), or pass --selector here \
        to click it for you. Use `drive type --key Enter` for a named key.
        """
    )

    @Argument(help: "The text to type. Omit when using --key.")
    var text: String?

    @Option(name: .long, help: "Press a single named key instead (Enter, Tab, Escape, ArrowDown, …).")
    var key: String?

    @Option(name: .long, help: "Click this element first, so the text goes somewhere.")
    var selector: String?

    @OptionGroup var options: DriveOptions

    func run() async throws {
        try await DriveSession.run(options) { client in
            if let selector {
                let point = try client.center(of: selector, window: options.window)
                for phase in ["down", "up"] {
                    try client.invoke("input.pointer", pointerPayload(phase: phase, point: point))
                }
            }
            if let key {
                try press(client, key: key, text: nil)
                print("Pressed \(key).")
                return
            }
            guard let text, !text.isEmpty else {
                throw ValidationError("Give some text to type, or --key <name>.")
            }
            for character in text {
                try press(client, key: String(character), text: String(character))
            }
            print("Typed \(text.count) character\(text.count == 1 ? "" : "s").")
        }
    }

    private func pointerPayload(phase: String, point: (x: Double, y: Double)) -> [String: BridgeJSON] {
        var payload: [String: BridgeJSON] = [
            "type": .string(phase), "x": .number(point.x), "y": .number(point.y)
        ]
        if let window = options.window { payload["window"] = .string(window) }
        return payload
    }

    private func press(_ client: DriverClient, key: String, text: String?) throws {
        for phase in ["down", "up"] {
            var payload: [String: BridgeJSON] = ["type": .string(phase), "key": .string(key)]
            if let text { payload["text"] = .string(text) }
            if let window = options.window { payload["window"] = .string(window) }
            try client.invoke("input.key", payload)
        }
    }
}

struct DriveScroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Scroll the page with a wheel event.",
        discussion: """
        Positive amounts scroll the content down and right — the DOM's sign convention, whatever \
        the platform's native direction or "natural scrolling" setting.
        """
    )

    @Argument(help: "Vertical scroll distance in CSS pixels. Positive scrolls down.")
    var amount: Double

    @Option(name: .long, help: "Horizontal scroll distance in CSS pixels.")
    var dx: Double = 0

    @Option(name: .long, help: "Scroll over the centre of this element rather than the viewport's.")
    var selector: String?

    @OptionGroup var options: DriveOptions

    func run() async throws {
        try await DriveSession.run(options) { client in
            let point: (x: Double, y: Double) = if let selector {
                try client.center(of: selector, window: options.window)
            } else {
                // The viewport centre: with nested scrollers, *where* you scroll
                // decides *what* scrolls.
                try {
                    let viewport = try client.viewportSize(window: options.window)
                    return (viewport.width / 2, viewport.height / 2)
                }()
            }
            var payload: [String: BridgeJSON] = [
                "x": .number(point.x), "y": .number(point.y),
                "deltaX": .number(dx), "deltaY": .number(amount)
            ]
            if let window = options.window { payload["window"] = .string(window) }
            try client.invoke("input.wheel", payload)
            print("Scrolled \(Int(amount)) px vertically\(dx == 0 ? "" : ", \(Int(dx)) px horizontally").")
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
    /// `log` is where lifecycle chatter (and the build's own output) goes.
    /// Defaults to stdout for the CLI; the MCP server passes stderr, because
    /// its stdout carries the protocol stream and must contain nothing else.
    static func run(
        _ options: DriveOptions,
        log: FileHandle = .standardOutput,
        _ body: (DriverClient) throws -> Void
    ) async throws {
        if let port = options.attach {
            guard let token = options.token else {
                throw ValidationError("--attach needs the --token the app printed at launch.")
            }
            let client = try DriverClient(port: UInt16(port), token: token)
            try prepare(client, options)
            try body(client)
            return
        }

        let app = try await LaunchedApp.build(options, log: log)
        defer { app.terminate() }
        let client = try DriverClient(port: app.port, token: app.token)
        try prepare(client, options)
        try body(client)
    }

    /// Both waits are client-side (see `DriverClient.wait`): a page-ready poll
    /// so `drive shot` doesn't photograph a blank window straight after launch,
    /// then the caller's own `--wait` expression.
    static func prepare(_ client: DriverClient, _ options: DriveOptions) throws {
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
    static func build(_ options: DriveOptions, log: FileHandle = .standardOutput) async throws -> LaunchedApp {
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

        log.writeQuietly(Data("Building \(exe) (\(options.configuration))…\n".utf8))
        // `swift` by bare name, not `/usr/bin/env swift`: there is no
        // `/usr/bin/env` on Windows, so the launcher form fails before the build
        // even starts. `Shell.resolveExecutable` does a PATH search on every
        // platform (adding `.exe` / `.cmd` / `.bat` on Windows), which resolves
        // to the same binary `env` would have found.
        try await Shell.run(
            "swift",
            ["build", "-c", options.configuration, "--product", exe],
            cwd: cwd,
            stdoutTo: log
        )
        let binPath = try await Shell.capture(
            "swift",
            ["build", "-c", options.configuration, "--show-bin-path"],
            cwd: cwd
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        var executable = URL(fileURLWithPath: binPath).appendingPathComponent(exe)
        #if os(Windows)
            executable = executable.appendingPathExtension("exe")
        #endif
        guard fm.fileExists(atPath: executable.path) else {
            throw DriveError.launch("built \(exe) but found no executable at \(executable.path)")
        }

        let webRoot = cwd.appendingPathComponent(pwa.web.directory)
        stageWebRoot(webRoot, besideBinaryAt: URL(fileURLWithPath: binPath), log: log)

        return try launch(
            executable: executable,
            cwd: cwd,
            timeout: options.timeout,
            route: options.route,
            webRoot: webRoot
        )
    }

    /// Make the app's `web/` reachable from the bare SwiftPM binary.
    ///
    /// `swift-pwa build` stages `web/` into the bundle; plain `swift build`
    /// doesn't stage anything, so a driven app looks for
    /// `<bin-path>/web` and finds nothing. Apps built against a runtime with
    /// `WindowContent.bundledWeb` read `SWIFT_PWA_WEB_ROOT` instead and don't
    /// need this — but an app scaffolded before that still resolves
    /// `Bundle.main.resourceURL/web` and dies before the driver can attach, so
    /// a **symlink** puts the real directory exactly where it looks.
    ///
    /// A symlink rather than a copy because a real app's web directory is not
    /// small — one adopter's is 2.2 GB of art, and a per-build copy of that is
    /// not a fix. Best-effort: if it can't be made, the launch still goes ahead
    /// (the env var may well carry it) and the app's own error explains the
    /// rest.
    private static func stageWebRoot(_ webRoot: URL, besideBinaryAt binDir: URL, log: FileHandle) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: webRoot.path) else { return }
        let link = binDir.appendingPathComponent("web")

        // Leave a real directory alone — that's a build product, not ours to
        // replace. Refresh only a link we could have made ourselves.
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if existing == webRoot.path { return }
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            return
        }

        do {
            try fm.createSymbolicLink(at: link, withDestinationURL: webRoot)
        } catch {
            log.writeQuietly(Data("""
            swift-pwa: couldn't link web/ next to the binary (\(error.localizedDescription)). \
            If the app can't find its web bundle, it was built before \
            `WindowContent.bundledWeb` — see docs/app-driver.md.\n
            """.utf8))
        }
    }

    private static func launch(
        executable: URL,
        cwd: URL,
        timeout: TimeInterval,
        route: String?,
        webRoot: URL? = nil
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
        // Point the runtime at the project's real web/ rather than hoping one
        // was staged. Handles the cases a staged link can't: a web directory
        // outside the SwiftPM target (`../public`), and a tree too large to
        // declare as a SwiftPM resource.
        if let webRoot { env[WebRoot.environmentVariable] = webRoot.path }
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
            // Lead with what actually happened. An app that *exited* almost
            // always died in `configure` — most often because it couldn't find
            // its web bundle — and telling that person to check their build
            // configuration sends them somewhere else entirely.
            if !process.isRunning {
                throw DriveError.launch("""
                the app exited (status \(process.terminationStatus)) before announcing a driver port.

                Its own output is above — a `configure` that throws or calls fatalError lands here. The \
                usual cause is the web bundle: a bare `swift build` doesn't stage one. `drive` links \
                yours next to the binary and sets \(WebRoot.environmentVariable), which an app using \
                `WindowContent.bundledWeb` picks up; an app scaffolded before that resolves \
                `Bundle.main.resourceURL/web` itself and may need updating. See docs/app-driver.md.
                """)
            }
            process.terminate()
            throw DriveError.launch("""
            the app is running but never announced a driver port.

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
