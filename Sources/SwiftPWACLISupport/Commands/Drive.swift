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

        An iOS device is the exception to the backgrounding story: iOS suspends an app that isn't \
        frontmost, and a verb sent to a suspended app doesn't fail — it waits, and completes when \
        the app comes forward. Keep the app on screen for the duration of a run.
        """,
        subcommands: [
            DriveEval.self, DriveShot.self, DriveClick.self, DriveDrag.self,
            DriveType.self, DriveScroll.self, DriveWindows.self, DriveInfo.self
        ]
    )
}

// MARK: - Shared options

struct DriveOptions: ParsableArguments {
    @Option(name: .long, help: "Path to pwa.json (used to resolve the executable). Defaults to ./pwa.json.")
    var manifest: String = "pwa.json"

    @Option(name: .long, help: "Build configuration to launch: debug (default) or release.")
    var configuration: String = "debug"

    @Option(
        name: .long,
        help: """
        Where to run the app: the host (default), or ios — a cabled device by default, or the \
        simulator with --simulator. A device needs USB: the control socket is on the device's own \
        loopback, and only the USB transport relays into it (installing and launching work over \
        Wi-Fi, driving doesn't).
        """
    )
    var target: BuildTarget = .host

    @Flag(help: "Run on the iOS Simulator rather than a device (implies --target ios).")
    var simulator: Bool = false

    @Option(
        name: .long,
        help: "iOS device or simulator name/UDID. Defaults to the sole connected device, or a booted simulator."
    )
    var device: String?

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

    @Flag(
        name: .long,
        help: """
        Launch the app off screen, without activating it. For a suite that launches one app per \
        test file, where the default — every launch coming to the front — means the machine can't be \
        used for the length of the run. The page keeps rendering at full rate; macOS only so far.
        """
    )
    var background: Bool = false

    // MARK: iOS device signing

    //
    // An on-device build has to be signed before it will install, so `drive`
    // takes the same signing options `build` and `deploy` do and passes them
    // straight through. They're inert for every other target.

    @Option(name: .long, help: "iOS device: a 10-character Apple Developer Team ID to sign with.")
    var team: String?

    @Option(name: .long, help: "iOS/macOS: codesign identity (e.g. \"Apple Development: …\").")
    var sign: String?

    @Option(name: .long, help: "iOS device: path to a provisioning profile (.mobileprovision).")
    var provisioningProfile: String?

    @Option(name: .long, help: "iOS device: path to an entitlements plist (pair with --provisioning-profile).")
    var entitlements: String?

    @Flag(help: "iOS device: let --team mint a provisioning profile for a free personal Apple team.")
    var allowProvisioningRegistration: Bool = false

    /// Whether this run goes to the iOS Simulator rather than the host.
    var runsOnSimulator: Bool {
        simulator
    }

    /// Whether this run goes to a physically-attached iOS device. `--target ios`
    /// means the device now; the simulator is the one that needs asking for.
    var runsOnDevice: Bool {
        target == .ios && !simulator
    }

    func validate() throws {
        if simulator, target != .ios, target != .host {
            throw ValidationError("--simulator is iOS-only; drop --target \(target.rawValue).")
        }
        // Refused rather than ignored on iOS: the platform's own answer to a
        // backgrounded app is to suspend it, and a verb sent to a suspended app
        // doesn't fail — it queues and answers when the app comes forward. A
        // silently-accepted flag would turn that into a run that appears to
        // hang.
        if background, runsOnSimulator || runsOnDevice {
            throw ValidationError("""
            --background is desktop-only. iOS suspends an app that isn't frontmost, and a verb sent to a \
            suspended app queues instead of failing — keep the app on screen for an iOS run.
            """)
        }
        if background, attach != nil {
            throw ValidationError("""
            --background applies to a launch, and --attach talks to an app that is already running. \
            Launch that app with SWIFT_PWA_DRIVE_BACKGROUND=1 set, or drop --attach.
            """)
        }
        #if !os(macOS)
            if runsOnSimulator {
                throw ValidationError("the iOS Simulator is only available on macOS.")
            }
            if runsOnDevice {
                throw ValidationError("driving an iOS device is only available on macOS.")
            }
        #endif
    }
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
            // A promise is awaited automatically: no backend resolves one, so
            // the alternative is failing with a serialization complaint that
            // never mentions promises. Bounded by `--timeout`.
            if let settled = try client.evalAwaitingPromise(
                script,
                timeout: options.timeout,
                window: options.window
            ) {
                print(settled.prettyPrinted)
                return
            }
            // The page's CSP forbids `eval`, so the script hasn't run yet.
            // Evaluate it directly — the pre-0.10 path, minus promise support.
            var payload: [String: BridgeJSON] = ["js": .string(script)]
            if let window = options.window {
                payload["window"] = .string(window)
            }
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
            if let window = options.window {
                payload["window"] = .string(window)
            }
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
                if let window = options.window {
                    payload["window"] = .string(window)
                }
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

/// Parses `--modifiers` for the verbs that take it.
///
/// The wire accepts these; `InputModifiers(names:)` ignores anything else so a
/// newer client can't break an older app. At the CLI that leniency is the wrong
/// trade — a typo'd `--modifiers commnd` would send an unmodified keystroke and
/// report success, which is a measurement that lies — so names are checked here
/// and a bad one is a usage error.
enum DriveModifiers {
    private static let names: Set<String> = [
        "shift", "control", "ctrl", "alt", "option", "meta", "command", "cmd"
    ]

    static func parse(_ raw: String?) throws -> [String] {
        guard let raw else { return [] }
        let parsed = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if let unknown = parsed.first(where: { !names.contains($0) }) {
            throw ValidationError(
                "Unknown modifier \"\(unknown)\". Use shift, control, alt or command."
            )
        }
        return parsed
    }
}

/// One end of a drag, as `x,y`.
///
/// A dedicated type rather than two options per point so `--to` can repeat and
/// still read as a path: `--from 20,20 --to 200,20 --to 200,200`.
struct DragPoint: ExpressibleByArgument {
    var x: Double
    var y: Double

    init?(argument: String) {
        let parts = argument.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        self.x = x
        self.y = y
    }

    static var defaultValueDescription: String {
        "x,y"
    }
}

struct DriveDrag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drag",
        abstract: "Press, move and release — a drag gesture along a path.",
        discussion: """
        The moves in between are the point. A press and a release at two coordinates with nothing         between them doesn't drive momentum, inertia, rubber-banding, or anything else that reads         velocity — which is most of what a drag gesture is for — so this interpolates a path and         paces it over --duration.

        --to repeats, so a multi-segment gesture is one command:

          swift-pwa drive drag --from 20,20 --to 200,20 --to 200,200

        Coordinates are window-local CSS pixels, or viewport fractions with --fraction. Prefer         --from-selector / --to-selector where the endpoints are elements: they survive a layout         change, and each is measured immediately before the gesture starts.
        """
    )

    @Option(name: .long, help: "Where the drag starts, as x,y. Omit when using --from-selector.")
    var from: DragPoint?

    @Option(name: .long, help: "A point to drag to, as x,y. Repeat for a multi-segment path.")
    var to: [DragPoint] = []

    @Option(name: .long, help: "Start at the centre of the first element matching this CSS selector.")
    var fromSelector: String?

    @Option(name: .long, help: "End at the centre of the first element matching this CSS selector.")
    var toSelector: String?

    @Flag(help: "Treat coordinates as fractions of the viewport (0-1) rather than CSS pixels.")
    var fraction: Bool = false

    @Option(
        name: .long,
        help: """
        How long the gesture takes, in milliseconds. Real elapsed time, because a page reading \
        velocity gets a different answer from the same path delivered faster.
        """
    )
    var duration: Double = 250

    @Option(name: .long, help: "Intermediate move events across the whole path. Default: one per ~8ms.")
    var steps: Int?

    @Option(name: .long, help: "Which button to hold: left (default), right, middle, barrel or eraser.")
    var button: String = "left"

    @Option(name: .long, help: "Pointer type: mouse (default), pen or touch. Refused if the backend can't produce it.")
    var pointerType: String = "mouse"

    @Option(
        name: .long,
        help: "Modifiers held for the whole gesture, comma-separated: shift, control, alt, command."
    )
    var modifiers: String?

    @OptionGroup var options: DriveOptions

    func run() async throws {
        // Validated before the app is built and launched: a usage error should
        // cost a usage error, not a compile and a window.
        let held = try DriveModifiers.parse(modifiers)
        guard duration >= 0 else {
            throw ValidationError("--duration can't be negative.")
        }
        if let steps, steps < 1 {
            throw ValidationError("--steps must be at least 1.")
        }
        if from == nil, fromSelector == nil {
            throw ValidationError("Give a start point: --from x,y or --from-selector <css>.")
        }
        if from != nil, fromSelector != nil {
            throw ValidationError("Give --from or --from-selector, not both.")
        }
        if toSelector != nil, !to.isEmpty {
            throw ValidationError("Give --to or --to-selector, not both.")
        }
        if to.isEmpty, toSelector == nil {
            throw ValidationError("Give somewhere to drag to: --to x,y or --to-selector <css>.")
        }

        try await DriveSession.run(options) { client in
            let path = try resolvePath(client)
            let plan = Self.interpolate(path, steps: steps ?? Self.defaultSteps(forMilliseconds: duration))
            let interval = plan.count > 1 ? duration / 1000 / Double(plan.count - 1) : 0

            // A move before the press: a real gesture hovers first, and a page
            // whose handler arms on pointerover would otherwise never see it.
            try send(client, phase: "move", at: path[0], modifiers: held)
            try send(client, phase: "down", at: path[0], modifiers: held)

            // Paced to a deadline, not by sleeping between sends. Every move is
            // a synchronous round trip to the app, so adding a fixed sleep to
            // each one overshoots — measured at ~2x on a local macOS app, and a
            // page computing velocity would read a slower gesture than the one
            // that was asked for.
            let start = Date()
            for (index, point) in plan.dropFirst().enumerated() {
                let due = start.addingTimeInterval(Double(index + 1) * interval)
                let wait = due.timeIntervalSinceNow
                if wait > 0 {
                    Thread.sleep(forTimeInterval: wait)
                }
                try send(client, phase: "move", at: point, modifiers: held, holding: true)
            }
            let elapsed = Date().timeIntervalSince(start) * 1000
            try send(client, phase: "up", at: plan[plan.count - 1], modifiers: held)

            let route = path.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " → ")
            var line = "Dragged \(route) in \(plan.count - 1) move\(plan.count == 2 ? "" : "s") over \(Int(elapsed)) ms."
            // Round trips can't be compressed, so a short --duration with many
            // steps is simply unachievable. Say so rather than let a velocity
            // assertion fail against a gesture that was never delivered at the
            // requested speed.
            if elapsed > duration * 1.25, duration > 0 {
                line += " Asked for \(Int(duration)) ms — the app couldn't be driven that fast;"
                line += " use fewer --steps for a quicker gesture."
            }
            print(line)
        }
    }

    /// The gesture's corners, in window-local CSS pixels.
    private func resolvePath(_ client: DriverClient) throws -> [DragPoint] {
        var viewport: (width: Double, height: Double)?
        func scaled(_ point: DragPoint) throws -> DragPoint {
            guard fraction else { return point }
            let size = try viewport ?? client.viewportSize(window: options.window)
            viewport = size
            return DragPoint(argument: "\(point.x * size.width),\(point.y * size.height)")!
        }

        var path: [DragPoint] = []
        if let fromSelector {
            let centre = try client.center(of: fromSelector, window: options.window)
            path.append(DragPoint(argument: "\(centre.x),\(centre.y)")!)
        } else if let from {
            try path.append(scaled(from))
        }
        if let toSelector {
            let centre = try client.center(of: toSelector, window: options.window)
            path.append(DragPoint(argument: "\(centre.x),\(centre.y)")!)
        } else {
            for point in to { try path.append(scaled(point)) }
        }
        return path
    }

    private func send(
        _ client: DriverClient,
        phase: String,
        at point: DragPoint,
        modifiers: [String],
        holding: Bool = false
    ) throws {
        var payload: [String: BridgeJSON] = [
            "type": .string(phase),
            "x": .number(point.x),
            "y": .number(point.y),
            "button": .string(button),
            "pointerType": .string(pointerType)
        ]
        // Says this move is a drag rather than a hover. Without it the
        // platforms deliver a different event entirely (or none) and the page
        // sees a press and a release with no path between them.
        if holding {
            payload["buttons"] = .array([.string(button)])
        }
        if !modifiers.isEmpty {
            payload["modifiers"] = .array(modifiers.map { .string($0) })
        }
        if let window = options.window {
            payload["window"] = .string(window)
        }
        try client.invoke("input.pointer", payload)
    }

    /// ~8 ms per move — about half a 60 Hz frame, so a page sampling per frame
    /// sees a fresh position every time — bounded at both ends. The floor keeps
    /// a `--duration 0` gesture from collapsing to a press and a release; the
    /// ceiling keeps a long drag from spending its whole budget on round trips,
    /// each of which is a synchronous request to the app.
    static func defaultSteps(forMilliseconds duration: Double) -> Int {
        min(60, max(8, Int((duration / 8).rounded())))
    }

    /// `steps` points along the path, corners included.
    ///
    /// Steps are spread by *distance*, not per segment, so an L-shaped drag
    /// doesn't crawl along its short leg and jump along its long one — a page
    /// reading velocity would see two different gestures.
    static func interpolate(_ path: [DragPoint], steps: Int) -> [DragPoint] {
        guard path.count > 1 else { return path }
        let lengths = zip(path, path.dropFirst()).map { a, b in
            (pow(b.x - a.x, 2) + pow(b.y - a.y, 2)).squareRoot()
        }
        let total = lengths.reduce(0, +)
        var result = [path[0]]
        for (index, length) in lengths.enumerated() {
            // A zero-length segment still gets one step: the caller asked to
            // pass through that corner, and dropping it would silently change
            // the path.
            let share = total > 0 ? Int((Double(steps) * length / total).rounded()) : steps / lengths.count
            let count = max(1, share)
            let a = path[index]
            let b = path[index + 1]
            for step in 1 ... count {
                let t = Double(step) / Double(count)
                result.append(DragPoint(argument: "\(a.x + (b.x - a.x) * t),\(a.y + (b.y - a.y) * t)")!)
            }
        }
        return result
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

        --modifiers holds keys down for the keystroke, so shortcuts are drivable: \
        `drive type --key a --modifiers command` is Select All. On macOS these reach the \
        app's menu bar the way a real keystroke does, which is what makes the editing \
        shortcuts (⌘A / ⌘C / ⌘V / ⌘X / ⌘Z) testable at all.
        """
    )

    @Argument(help: "The text to type. Omit when using --key.")
    var text: String?

    @Option(name: .long, help: "Press a single named key instead (Enter, Tab, Escape, ArrowDown, …).")
    var key: String?

    @Option(
        name: .long,
        help: "Modifiers held for the keystroke, comma-separated: shift, control, alt, command."
    )
    var modifiers: String?

    @Flag(
        name: .long,
        help: """
        Bring the app forward for the keystroke. Needed on macOS for menu shortcuts         (⌘C / ⌘V / ⌘A / ⌘Z): they are dispatched to the key window, and an app that         isn't active doesn't have one, so they do nothing without this. Typing and         page-level shortcuts don't need it.
        """
    )
    var activate: Bool = false

    @Option(name: .long, help: "Click this element first, so the text goes somewhere.")
    var selector: String?

    @OptionGroup var options: DriveOptions

    func run() async throws {
        // Parsed before the app is launched, so a typo'd modifier costs a usage
        // error rather than a build and a run.
        let held = try DriveModifiers.parse(modifiers)
        let withHeld = held.isEmpty ? "" : " with \(held.joined(separator: "+"))"
        try await DriveSession.run(options) { client in
            if let selector {
                let point = try client.center(of: selector, window: options.window)
                for phase in ["down", "up"] {
                    try client.invoke("input.pointer", pointerPayload(phase: phase, point: point))
                }
            }
            if let key {
                try press(client, key: key, text: nil, modifiers: held)
                print("Pressed \(key)\(withHeld).")
                return
            }
            guard let text, !text.isEmpty else {
                throw ValidationError("Give some text to type, or --key <name>.")
            }
            for character in text {
                try press(client, key: String(character), text: String(character), modifiers: held)
            }
            print("Typed \(text.count) character\(text.count == 1 ? "" : "s")\(withHeld).")
        }
    }

    private func pointerPayload(phase: String, point: (x: Double, y: Double)) -> [String: BridgeJSON] {
        var payload: [String: BridgeJSON] = [
            "type": .string(phase), "x": .number(point.x), "y": .number(point.y)
        ]
        if let window = options.window {
            payload["window"] = .string(window)
        }
        return payload
    }

    private func press(_ client: DriverClient, key: String, text: String?, modifiers: [String]) throws {
        for phase in ["down", "up"] {
            var payload: [String: BridgeJSON] = ["type": .string(phase), "key": .string(key)]
            if let text {
                payload["text"] = .string(text)
            }
            if !modifiers.isEmpty {
                payload["modifiers"] = .array(modifiers.map { .string($0) })
            }
            if activate {
                payload["activate"] = .bool(true)
            }
            if let window = options.window {
                payload["window"] = .string(window)
            }
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
            if let window = options.window {
                payload["window"] = .string(window)
            }
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
        if options.background { warnIfNotBackgrounded(client) }
        warnIfWindowHidden(client, options)
    }

    /// Say so when `--background` was asked for and the app didn't do it.
    ///
    /// The request travels as an environment variable, which a backend that
    /// hasn't implemented backgrounding ignores in silence — and the symptom of
    /// that is indistinguishable from the flag not existing: every launch keeps
    /// coming to the front. So the app reports what it actually did
    /// (`capabilities.background`) and this repeats it, once, rather than
    /// leaving someone to conclude the flag is broken.
    private static func warnIfNotBackgrounded(_ client: DriverClient) {
        guard let capabilities = try? client.invoke("capabilities", [:]) else { return }
        guard capabilities["background"]?.isTruthy != true else { return }
        let backend = capabilities["backend"]?.stringValue ?? "this"
        FileHandle.standardError.writeQuietly(Data("""
        swift-pwa: --background had no effect — the \(backend) backend didn't take it, so this run \
        shows the app's window like any other. macOS, GTK3 and Windows implement it; GTK4 can't (it has no \
        window positioning, so run the whole command under a nested display instead: \
        `xvfb-run -a swift-pwa drive …`). An app built against an earlier swift-pwa doesn't have it either.\n
        """.utf8))
    }

    /// Say so when the target window isn't on screen.
    ///
    /// WebKit throttles (or stops) `requestAnimationFrame` for a window the
    /// compositor isn't showing, so a page that draws or restores state in a rAF
    /// callback silently does nothing while it's covered — and `drive shot`
    /// returns a clean screenshot of the stale content, which reads as an app bug
    /// rather than an environment one. An adopter lost an hour to this twice
    /// ("EPUB renders nothing", "reading position isn't restored"; both fine when
    /// visible). The driver can't stop WebKit throttling, so the least it can do
    /// is not let you debug the wrong thing.
    ///
    /// Best-effort and quiet on anything unexpected: this is a diagnostic, and it
    /// must never be the reason a verb fails. Backends with no occlusion query
    /// report `unknown`, which says nothing rather than guessing.
    private static func warnIfWindowHidden(_ client: DriverClient, _ options: DriveOptions) {
        guard let windows = try? client.invoke("window.list", [:]),
              case let .array(entries) = windows
        else { return }
        let target = entries.first { entry in
            guard let id = options.window else { return true } // default: the only/first window
            return entry["id"]?.stringValue == id
        }
        guard target?["visibility"]?.stringValue == WindowVisibility.hidden.rawValue else { return }
        let id = target?["id"]?.stringValue ?? "?"
        FileHandle.standardError.writeQuietly(Data("""
        swift-pwa: window \(id) isn't on screen (occluded, minimized, or on another Space).
          WebKit throttles requestAnimationFrame for a window the compositor isn't showing, so a page \
        that draws or restores state in a rAF callback will appear to do nothing — and a screenshot \
        will capture that stale state cleanly. Bring the window to the front if the run depends on \
        rendering.\n
        """.utf8))
    }
}

/// An app process `drive` started and owns.
struct LaunchedApp {
    let process: Process
    let port: UInt16
    let token: String
    /// Teardown for a launch where `process` isn't the app itself. On the
    /// simulator it's simctl's console relay, and killing that leaves the app
    /// running — so the run also has to `simctl terminate`.
    var stop: (() -> Void)?

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
        if options.runsOnSimulator {
            return try await buildForSimulator(options, log: log)
        }
        if options.runsOnDevice {
            return try await buildForDevice(options, log: log)
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
            ["build", "-c", options.configuration, "--product", exe]
                + NativeLibrarySearch.hostLinkerArgs(manifest: pwa, projectRoot: cwd)
                + NativeLibrarySearch.hostCompilerArgs(manifest: pwa, projectRoot: cwd),
            cwd: cwd,
            stdoutTo: progressSink
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
            webRoot: webRoot,
            displayName: pwa.name,
            background: options.background,
            runtimeEnvironment: NativeLibrarySearch.hostRuntimeEnvironment(manifest: pwa, projectRoot: cwd)
        )
    }

    // The simulator path: bundle a real `.app` (via the same `build --target
    // ios --simulator` an adopter runs), install it, launch it with the driver
    // asked for, and read the handshake off the app's console.
    //
    // Nothing here is new machinery on the app's side — the iOS runtime has
    // started the control socket since it shipped. What was missing was a way to
    // get a *debug* build onto a simulator and read its stdout: `deploy` built
    // release only, so the socket wasn't compiled in, and an iPad layout could
    // only be checked by deploy → screenshot → crop → squint, once per change.
    //
    // macOS-only at the source level, not just at runtime: the body reaches for
    // `simctl` and for POSIX `dup2` / `fflush(stdout)`, neither of which is
    // portable — glibc types `stdout` as a mutable global (a strict-concurrency
    // error on Linux) and Windows spells the fd calls `_dup2` / `_close`.
    #if os(macOS)
        private static func buildForSimulator(
            _ options: DriveOptions, log: FileHandle
        ) async throws -> LaunchedApp {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let pwa: PWAManifest
            do {
                pwa = try PWAManifest.load(from: cwd.appendingPathComponent(options.manifest))
            } catch {
                throw ValidationError(
                    "Couldn't read \(options.manifest): \(error). Run `swift-pwa drive` from your app's directory."
                )
            }
            let outputDir = cwd.appendingPathComponent(
                Build.resolveOutput(nil, target: .ios, simulator: true)
            )
            let app = outputDir.appendingPathComponent("\(pwa.name).app")
            let bundleID = pwa.ios?.bundleIdentifier ?? pwa.id

            let sink = progressSink
            let udid = try await withStdout(redirectedTo: sink) {
                // `build` prints with `print(...)`, and xcodebuild inherits our
                // stdout — both would land in the MCP protocol stream, so the
                // whole build+install phase writes where lifecycle chatter goes.
                sink.writeQuietly(Data("→ building \(pwa.name) for the simulator (\(options.configuration))\n".utf8))
                let build = try Build.parse([
                    "--target", "ios", "--simulator",
                    "--configuration", options.configuration,
                    "--manifest", options.manifest
                ])
                try await build.run()
                let udid = try await SimulatorControl.resolve(explicit: options.device, log: sink)
                sink.writeQuietly(Data("→ installing \(app.lastPathComponent) to simulator \(udid)\n".utf8))
                SimulatorControl.terminate(bundleID: bundleID, on: udid)
                try await SimulatorControl.install(app: app, on: udid, log: sink)
                sink.writeQuietly(Data("→ launching \(bundleID)\n".utf8))
                return udid
            }

            var childEnvironment = [AppDriver.environmentVariable: "0"]
            if let route = options.route {
                childEnvironment[InitialRoute.environmentVariable] = route
            }
            let stdout = Pipe()
            let handshake = HandshakeReader()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                handshake.consume(data)
            }
            let relay = try SimulatorControl.launchProcess(
                bundleID: bundleID, on: udid, childEnvironment: childEnvironment, stdout: stdout
            )
            guard let announcement = handshake.wait(seconds: min(options.timeout, 60)) else {
                relay.terminate()
                SimulatorControl.terminate(bundleID: bundleID, on: udid)
                throw DriveError.launch("""
                the app launched on simulator \(udid) but never announced a driver port.

                The control socket is compiled into debug builds only — drop --configuration release. \
                If this *was* a debug build, the app's own output is above.
                """)
            }
            // The app's loopback is the host's, which is the whole reason this
            // works: connect to 127.0.0.1 on the port it just printed.
            return LaunchedApp(
                process: relay,
                port: announcement.port,
                token: announcement.token,
                stop: { SimulatorControl.terminate(bundleID: bundleID, on: udid) }
            )
        }
        /// The device path. Everything the *app* needs has been in place since
        /// the driver shipped — `IOSSceneDelegate` starts the control socket like
        /// every other backend. What was missing was purely host-side plumbing,
        /// and the guess in the issue behind this (that `devicectl` could forward
        /// a port) turned out to be wrong: it has no networking verb at all.
        ///
        /// So the four gates are met by four different mechanisms:
        ///   1. compiled in — a debug build, same as everywhere
        ///   2. SWIFT_PWA_DRIVE — `devicectl … launch -e`
        ///   3. the token — read off `--console`, which relays the app's stdout
        ///   4. the socket — `USBMux`, because the port is on the *device's*
        ///      loopback and only the USB transport relays into it
        ///
        /// Steps 1–3 work over Wi-Fi; only the socket needs a cable.
        private static func buildForDevice(
            _ options: DriveOptions, log _: FileHandle
        ) async throws -> LaunchedApp {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let pwa: PWAManifest
            do {
                pwa = try PWAManifest.load(from: cwd.appendingPathComponent(options.manifest))
            } catch {
                throw ValidationError(
                    "Couldn't read \(options.manifest): \(error). Run `swift-pwa drive` from your app's directory."
                )
            }
            let bundleID = pwa.ios?.bundleIdentifier ?? pwa.id
            let app = cwd
                .appendingPathComponent(Build.resolveOutput(nil, target: .ios, simulator: false))
                .appendingPathComponent("\(pwa.name).app")

            let sink = progressSink
            // Resolve before building: a signed device build takes minutes, and
            // "no device attached" should not cost them.
            let target = try await IOSDeviceResolver.resolve(explicit: options.device)

            try await withStdout(redirectedTo: sink) {
                sink.writeQuietly(Data("→ building \(pwa.name) for \(target.name) (\(options.configuration))\n".utf8))
                var arguments = [
                    "--target", "ios",
                    "--configuration", options.configuration,
                    "--manifest", options.manifest,
                    "--device", target.udid
                ]
                if let team = options.team { arguments += ["--team", team] }
                if let sign = options.sign { arguments += ["--sign", sign] }
                if let profile = options.provisioningProfile { arguments += ["--provisioning-profile", profile] }
                if let entitlements = options.entitlements { arguments += ["--entitlements", entitlements] }
                if options.allowProvisioningRegistration { arguments.append("--allow-provisioning-registration") }
                let build = try Build.parse(arguments)
                try await build.run()

                sink.writeQuietly(Data("→ installing \(app.lastPathComponent) to \(target.name)\n".utf8))
                try await Shell.run(
                    "/usr/bin/env",
                    ["xcrun", "devicectl", "device", "install", "app", "--device", target.udid, app.path],
                    stdoutTo: sink
                )
                sink.writeQuietly(Data("→ launching \(bundleID)\n".utf8))
            }

            var childEnvironment = [AppDriver.environmentVariable: "0"]
            if let route = options.route {
                childEnvironment[InitialRoute.environmentVariable] = route
            }
            let environmentJSON = try String(
                data: JSONSerialization.data(withJSONObject: childEnvironment, options: [.sortedKeys]),
                encoding: .utf8
            ) ?? "{}"

            let stdout = Pipe()
            let handshake = HandshakeReader()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                handshake.consume(data)
            }
            let console = Process()
            console.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            console.arguments = [
                "xcrun", "devicectl", "device", "process", "launch",
                "--device", target.udid,
                "--terminate-existing",
                // `--console` is what makes the handshake readable at all: it
                // attaches to the app's stdout and relays it here. It also means
                // this process stays alive for the app's lifetime, so signalling
                // it is how the app gets torn down (devicectl forwards catchable
                // signals to the app — `process terminate` would need a pid we
                // are never told).
                "--console",
                "-e", environmentJSON,
                bundleID
            ]
            console.standardOutput = stdout
            console.standardError = FileHandle.standardError
            try console.run()

            guard let announcement = handshake.wait(seconds: min(options.timeout, 60)) else {
                console.terminate()
                throw DriveError.launch("""
                the app launched on \(target.name) but never announced a driver port.

                The control socket is compiled into debug builds only — drop --configuration release. \
                A development-signed app also has to be trusted on the device once before it will run \
                (Settings → General → VPN & Device Management). If it did launch, its own output is above.
                """)
            }

            // The port is on the device's loopback, so it is reached through
            // usbmuxd rather than connected to directly. Everything downstream
            // talks to the local end and never learns a device was involved.
            let forwarder: USBMuxPortForwarder
            do {
                forwarder = try USBMux.forwarder(toDeviceSerial: target.udid, devicePort: announcement.port)
            } catch {
                console.terminate()
                throw DriveError.connect("\(error)")
            }

            sink.writeQuietly(Data(
                "→ forwarding 127.0.0.1:\(forwarder.localPort) to \(target.name) port \(announcement.port)\n".utf8
            ))
            return LaunchedApp(
                process: console,
                port: forwarder.localPort,
                token: announcement.token,
                stop: { forwarder.stop() }
            )
        }
    #else
        private static func buildForSimulator(
            _: DriveOptions, log _: FileHandle
        ) async throws -> LaunchedApp {
            throw ValidationError("the iOS Simulator is only available on macOS.")
        }

        private static func buildForDevice(
            _: DriveOptions, log _: FileHandle
        ) async throws -> LaunchedApp {
            throw ValidationError("driving an iOS device is only available on macOS.")
        }
    #endif

    /// Where a build's own output goes: **always stderr**, whoever is driving.
    ///
    /// Our stdout carries the verb's result and nothing else — `drive eval … |
    /// jq` has to keep working, and `swift-pwa mcp`'s stdout is the protocol
    /// stream, where one stray compiler line ends the session. That's the same
    /// reason `HandshakeReader` echoes the app's own output to stderr.
    ///
    /// A constant rather than a function of the lifecycle log because there is no
    /// caller who wants build chatter on stdout, and asking "is this handle our
    /// stdout?" isn't portable: `FileHandle.fileDescriptor` is unavailable on
    /// Windows ("Cannot perform non-owning handle to fd conversion").
    static var progressSink: FileHandle {
        .standardError
    }

    // Run `body` with this process's stdout pointed at `sink`.
    //
    // `drive` reuses `Build` in-process and `Build` reports progress with
    // `print(...)`, plus `xcodebuild` inherits our stdout. Both would land in
    // the verb's own output — and in `swift-pwa mcp`, whose stdout carries the
    // protocol stream, one stray line ends the session.
    #if os(macOS)
        private static func withStdout<T>(
            redirectedTo log: FileHandle, _ body: () async throws -> T
        ) async throws -> T {
            fflush(stdout)
            let saved = dup(FileHandle.standardOutput.fileDescriptor)
            dup2(log.fileDescriptor, FileHandle.standardOutput.fileDescriptor)
            defer {
                fflush(stdout)
                dup2(saved, FileHandle.standardOutput.fileDescriptor)
                close(saved)
            }
            return try await body()
        }
    #endif

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
            if existing == webRoot.path {
                return
            }
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
        webRoot: URL? = nil,
        displayName: String? = nil,
        background: Bool = false,
        runtimeEnvironment: [String: String] = [:]
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
        if let route {
            env[InitialRoute.environmentVariable] = route
        }
        // Point the runtime at the project's real web/ rather than hoping one
        // was staged. Handles the cases a staged link can't: a web directory
        // outside the SwiftPM target (`../public`), and a tree too large to
        // declare as a SwiftPM resource.
        if let webRoot {
            env[WebRoot.environmentVariable] = webRoot.path
        }
        // A bare `swift build` binary has no bundle to take its name from, so
        // it would answer the SwiftPM target name — and `app.documentsDir` is
        // derived from that name, which would send a driven run to an empty
        // folder beside the user's real one (#254).
        if let displayName, !displayName.isEmpty {
            env[AppPlugin.displayNameEnvironmentVariable] = displayName
        }
        // Off screen and never activated, so a suite can run while the machine
        // stays usable. The app decides whether it can honour that — the
        // `capabilities` verb reports what it actually did.
        if background {
            env[DriverBackground.environmentVariable] = "1"
        }
        // The binary runs straight out of `.build`, where no bundler has staged
        // the app's vendored libraries — without their directory on the
        // loader's path it dies at load rather than starting.
        for (key, value) in runtimeEnvironment { env[key] = value }
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
        if let stop {
            stop()
        }
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
final class HandshakeReader: @unchecked Sendable {
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
        if found != nil {
            semaphore.signal()
        }
    }

    func wait(seconds: TimeInterval) -> Announcement? {
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return announcement
    }

    /// Parses `swift-pwa driver listening port=51234 token=<hex>`.
    ///
    /// Fields are whitespace-trimmed, which is load-bearing for the simulator:
    /// `simctl launch --console-pty` relays the app's stdout through a PTY, whose
    /// line endings are CRLF, and a token with a trailing `\r` is silently the
    /// wrong token — the connection succeeds and every frame is refused.
    static func parse(_ line: String) -> Announcement? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("swift-pwa driver listening ") else { return nil }
        var port: UInt16?
        var token: String?
        for field in line.split(whereSeparator: \.isWhitespace) {
            if field.hasPrefix("port=") {
                port = UInt16(field.dropFirst(5))
            }
            if field.hasPrefix("token=") {
                token = String(field.dropFirst(6))
            }
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
