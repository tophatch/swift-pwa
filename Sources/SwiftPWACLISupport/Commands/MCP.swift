import ArgumentParser
#if canImport(CStbImage)
    import CStbImage // screenshot downscaling — see `PNGScaler`
#endif
import Foundation
import SwiftPWACore

/// Serves the app driver's verbs as **MCP tools** over stdio, so an agent can
/// change a stylesheet, screenshot the webview, and look at the result — with
/// no human present and without the machine being commandeered.
///
/// That loop costs a screen takeover and two TCC grants today, which is exactly
/// why nobody runs it and why UI regressions land unverified. Here the
/// screenshot comes from the app's own renderer and input goes into its own
/// event queue, so a driven session runs in the background while you keep
/// working.
///
/// **Dev-only by default, and gated the same three ways as `swift-pwa drive`**:
/// the driver isn't compiled into release builds, doesn't listen without
/// `SWIFT_PWA_DRIVE`, and requires a per-launch token.
///
/// `--agent` serves the *other* surface — a shipped app's own declared commands
/// (see [docs/agent-tools.md](../../../docs/agent-tools.md)). Same transport,
/// entirely different trust story: the driver can do anything to any debug
/// build, while the agent surface is an allowlist the developer wrote and the
/// user switched on for this session.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve an app's tools to an agent over MCP (stdio).",
        discussion: """
        Add to an MCP host's config as a stdio server whose command is `swift-pwa mcp`, with the \
        app's directory as the working directory. By default it serves the *driver's* verbs \
        (screenshot / eval / click) against a debug build it launches on the first tool call.

        With `--agent --attach <port> --token <token>` it instead serves a running app's own \
        declared commands, which is what the app shows you when a user turns agent access on. \
        Nothing is launched in that mode — the app is already running.

        Everything the server logs goes to stderr: stdout carries the protocol stream and must \
        contain nothing else.
        """
    )

    @OptionGroup var options: DriveOptions

    @Flag(help: "Serve a running app's own declared tools instead of the driver's verbs. Needs --attach/--token.")
    var agent: Bool = false

    func run() async throws {
        if agent, options.attach == nil {
            throw ValidationError("""
            --agent serves a running app, so it needs --attach <port> --token <token>. The app shows \
            both when a user turns agent access on.
            """)
        }
        // The driver's own lifecycle logging must not touch stdout.
        let server = MCPServer(options: options, agentMode: agent, log: .standardError)
        try await server.serve()
    }
}

// MARK: - Server

/// A minimal MCP server: JSON-RPC 2.0 over newline-delimited stdio.
///
/// Hand-rolled rather than pulled from a package, in keeping with the repo's
/// dependency-free default — the protocol surface this needs is `initialize`,
/// `tools/list`, `tools/call` and `ping`, which is a few hundred lines and no
/// new dependency to track.
final class MCPServer {
    /// Protocol versions this server knows how to speak. The spec's negotiation
    /// rule: echo the client's version when we support it, otherwise answer
    /// with our own latest and let the client decide whether to continue.
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let preferredProtocolVersion = "2025-06-18"

    private let options: DriveOptions
    /// `true` serves a running app's own declared tools; `false` serves the
    /// driver's verbs. The transport is identical — same newline-delimited
    /// frames, same token — so only the verb set and the tool catalogue differ.
    private let agentMode: Bool
    private let log: FileHandle
    private var app: LaunchedApp?
    private var client: DriverClient?
    /// Agent mode only: the app's tools, fetched once per session. The list is
    /// fixed at launch (it's compiled in), so re-asking per `tools/list` would
    /// buy nothing.
    private var agentTools: [AgentMCPTool]?

    init(options: DriveOptions, agentMode: Bool = false, log: FileHandle) {
        self.options = options
        self.agentMode = agentMode
        self.log = log
    }

    deinit {
        app?.terminate()
    }

    func serve() async throws {
        var pending = Data()
        while true {
            // Blocking read: this process exists only to serve one client, and
            // the host signals shutdown by closing our stdin.
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break } // EOF — the host disconnected
            pending.append(chunk)

            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex ..< newline]
                pending.removeSubrange(pending.startIndex ... newline)
                guard !line.isEmpty else { continue }
                if let response = await handle(line: Data(line)) {
                    send(response)
                }
            }
        }
        app?.terminate()
        app = nil
    }

    // MARK: - Dispatch

    private func handle(line: Data) async -> BridgeJSON? {
        guard let request = try? BridgeJSON.decode(line) else {
            return Self.error(id: .null, code: -32700, message: "parse error")
        }
        let id = request["id"] ?? .null
        guard case let .string(method)? = request["method"] else {
            return Self.error(id: id, code: -32600, message: "not a JSON-RPC request")
        }
        // A notification has no `id`, and per JSON-RPC gets no response at all.
        let isNotification = request["id"] == nil

        switch method {
        case "initialize":
            return Self.result(id: id, initializeResult(request["params"]))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            if agentMode {
                do {
                    let tools = try await loadAgentTools()
                    return Self.result(id: id, .object(["tools": .array(tools.map(\.descriptor))]))
                } catch {
                    // Listing is the first thing a host does, so a connection
                    // failure here is what the user will actually see — say what
                    // went wrong rather than returning an empty toolbox.
                    return Self.error(id: id, code: -32603, message: "\(error)")
                }
            }
            return Self.result(id: id, .object(["tools": .array(MCPTools.all.map(\.descriptor))]))
        case "tools/call":
            return await callTool(id: id, params: request["params"])
        default:
            if isNotification { return nil } // notifications/initialized, cancelled, …
            return Self.error(id: id, code: -32601, message: "unknown method '\(method)'")
        }
    }

    /// Version negotiation, per the spec: respond with the client's version
    /// when we support it, otherwise with our own latest and let the client
    /// decide whether to carry on or disconnect.
    static func negotiate(protocolVersion requested: String?) -> String {
        guard let requested, supportedProtocolVersions.contains(requested) else {
            return preferredProtocolVersion
        }
        return requested
    }

    private func initializeResult(_ params: BridgeJSON?) -> BridgeJSON {
        let version = Self.negotiate(protocolVersion: params?["protocolVersion"]?.stringValue)
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string("swift-pwa"),
                "title": .string(agentMode ? "swift-pwa app tools" : "swift-pwa app driver"),
                "version": .string(SwiftPWAVersion.current)
            ]),
            "instructions": .string(agentMode ? Self.agentInstructions : Self.driverInstructions)
        ])
    }

    static let driverInstructions = """
    Drives a locally built swift-pwa app: evaluate JavaScript in its page, take a \
    screenshot of the webview, click, type, scroll, and read window geometry. The app is \
    built and launched on the first tool call and torn down when this session ends.

    Screenshots are of the app's own rendered contents, not the screen, so the window can \
    stay in the background — you are not taking over the user's machine, and you should \
    not need to ask them to bring anything to the front.

    Not every backend can synthesize input. Call `app_capabilities` first if you intend to \
    click or type; where it isn't available, dispatch DOM events through `app_eval` \
    instead, bearing in mind those are untrusted events that skip default behaviour.
    """

    static let agentInstructions = """
    These are one running app's own commands, offered by its developer and switched on by \
    its user for this session only. They are not general computer control: this is the whole \
    surface, and anything not listed is refused.

    Read each tool's annotations before calling it. `readOnlyHint` means it only reads; \
    `destructiveHint` means it can remove or overwrite something the user cares about, and is \
    worth confirming with them first. The annotations are the app author's description of \
    their own commands, so treat them as a guide rather than a guarantee.

    Access can be revoked at any moment from the app — if calls start failing with an auth \
    error, the user has closed the door rather than something being broken.
    """

    private func callTool(id: BridgeJSON, params: BridgeJSON?) async -> BridgeJSON {
        guard case let .string(name)? = params?["name"] else {
            return Self.error(id: id, code: -32602, message: "tools/call needs a tool name")
        }
        let arguments = params?["arguments"] ?? .object([:])

        if agentMode {
            return await callAgentTool(id: id, name: name, arguments: arguments)
        }

        guard let tool = MCPTools.all.first(where: { $0.name == name }) else {
            return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
        }

        do {
            let client = try await connectedClient()
            let content = try tool.run(client, arguments, options)
            return Self.result(id: id, .object(["content": .array(content), "isError": .bool(false)]))
        } catch {
            // A failed tool call is a *result*, not a protocol error: the agent
            // should see what went wrong and be able to try something else,
            // rather than the session falling over.
            return Self.result(id: id, .object([
                "content": .array([.object(["type": .string("text"), "text": .string("\(error)")])]),
                "isError": .bool(true)
            ]))
        }
    }

    // MARK: - Agent mode

    /// Ask the running app what it offers, and lower each entry into an MCP
    /// tool descriptor.
    ///
    /// The app returns argument shapes as `BridgeSchema`; the JSON Schema
    /// lowering happens here rather than in the runtime, so fixing a mapping
    /// bug is a CLI update instead of an app rebuild.
    private func loadAgentTools() async throws -> [AgentMCPTool] {
        if let agentTools { return agentTools }
        let client = try await connectedClient()
        let result = try client.invoke("describe")
        guard case let .array(entries)? = result["tools"] else {
            throw DriveError.launch("the app didn't describe any tools")
        }

        var tools: [AgentMCPTool] = []
        for entry in entries {
            guard case let .string(name)? = entry["name"],
                  case let .string(description)? = entry["description"]
            else { continue }
            // `args` absent means a no-argument command.
            let schema: BridgeSchema = if let args = entry["args"], let data = try? args.encoded(),
                                          let decoded = try? JSONDecoder().decode(BridgeSchema.self, from: data)
            {
                decoded
            } else {
                .void
            }
            guard let inputSchema = JSONSchemaGenerator.toolInputSchema(for: schema) else {
                // `swift-pwa build` refuses these, but an app assembled without
                // that check can still reach here. Skipping is the honest
                // option: an agent can't call what we can't describe.
                log.writeQuietly(Data("swift-pwa: skipping '\(name)' — its arguments aren't describable\n".utf8))
                continue
            }
            tools.append(AgentMCPTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                annotations: entry["annotations"]
            ))
        }
        agentTools = tools
        return tools
    }

    private func callAgentTool(id: BridgeJSON, name: String, arguments: BridgeJSON) async -> BridgeJSON {
        do {
            let tools = try await loadAgentTools()
            guard tools.contains(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let client = try await connectedClient()
            // The app checks the allowlist again on its side; this one is just
            // so an unknown name is a protocol error rather than a round trip.
            let result = try client.invoke("call", [
                "name": .string(name),
                "arguments": arguments
            ])
            return Self.result(id: id, .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(result.prettyPrinted)
                ])]),
                "isError": .bool(false)
            ]))
        } catch {
            // A refusal or a handler failure is a *result*, so the agent can
            // read it and try something else instead of losing the session.
            return Self.result(id: id, .object([
                "content": .array([.object(["type": .string("text"), "text": .string("\(error)")])]),
                "isError": .bool(true)
            ]))
        }
    }

    /// Launch the app on first use and keep it for the session. Lazily, because
    /// an MCP host spawns its servers when it connects — building and opening a
    /// window at that moment, before the agent has asked for anything, would be
    /// a surprise.
    ///
    /// In agent mode nothing is ever launched: the app is already running, and
    /// starting a second copy would be both surprising and useless (its agent
    /// surface would be off).
    private func connectedClient() async throws -> DriverClient {
        if let client { return client }
        let client: DriverClient
        if let port = options.attach {
            guard let token = options.token else {
                throw DriveError.launch("--attach needs the --token the app printed at launch")
            }
            client = try DriverClient(port: UInt16(port), token: token)
            if agentMode {
                // No page-ready wait: `eval` isn't a verb on this channel, and
                // a shipped app is already up by the time a user has turned
                // access on and pasted the config.
                self.client = client
                return client
            }
        } else {
            let app = try await LaunchedApp.build(options, log: log)
            self.app = app
            client = try DriverClient(port: app.port, token: app.token)
        }
        // Wait for the page before the agent's first tool call sees anything.
        // A window's content loads from a task scheduled onto the UI thread, so
        // a freshly launched app sits on `about:blank` for a moment — and an
        // agent that screenshot that would conclude the app renders nothing.
        try DriveSession.prepare(client, options)
        self.client = client
        return client
    }

    // MARK: - Wire

    private func send(_ message: BridgeJSON) {
        guard var data = try? message.encoded() else { return }
        // Messages are newline-delimited and must not contain embedded
        // newlines — so never pretty-print here.
        data.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.writeQuietly(data)
    }

    private static func result(id: BridgeJSON, _ value: BridgeJSON) -> BridgeJSON {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private static func error(id: BridgeJSON, code: Int, message: String) -> BridgeJSON {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)])
        ])
    }
}

// MARK: - Agent tools

/// One of a running app's own tools, as the app described it.
///
/// Separate from ``MCPTool`` because it carries no `run` closure: the CLI
/// doesn't know what these commands do, and doesn't need to — it forwards the
/// call and the app decides.
struct AgentMCPTool: Equatable {
    let name: String
    let description: String
    let inputSchema: BridgeJSON
    /// The developer's risk annotations, passed through so a host can decide
    /// what to confirm. They're the app's claim, not something the CLI checks.
    let annotations: BridgeJSON?

    var descriptor: BridgeJSON {
        var fields: [String: BridgeJSON] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema
        ]
        if let annotations { fields["annotations"] = annotations }
        return .object(fields)
    }
}

// MARK: - Tools

struct MCPTool {
    let name: String
    let title: String
    let description: String
    let inputSchema: BridgeJSON
    let run: @Sendable (DriverClient, BridgeJSON, DriveOptions) throws -> [BridgeJSON]

    var descriptor: BridgeJSON {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema
        ])
    }
}

enum MCPTools {
    static let all: [MCPTool] = [
        screenshot, eval, click, typeText, pressKey, scroll, windows, capabilities
    ]

    // MARK: Observing

    static let screenshot = MCPTool(
        name: "app_screenshot",
        title: "Screenshot the app",
        description: """
        A PNG of the app's rendered webview contents. Not a screen capture: the window may be \
        behind other windows, on another desktop, or offscreen, and the image is still of the app \
        and only the app.
        """,
        inputSchema: object(properties: [
            "maxWidth": schema("integer", """
            Downscale so the image is at most this many pixels wide, preserving aspect ratio. \
            A full-resolution capture of a Retina window is several megabytes; 1024 is plenty to \
            see layout by.
            """)
        ]),
        run: { client, arguments, options in
            var payload: [String: BridgeJSON] = [:]
            if let window = options.window { payload["window"] = .string(window) }
            let result = try client.invoke("screenshot", payload)
            guard let base64 = result["pngBase64"]?.stringValue,
                  var png = Data(base64Encoded: base64)
            else { throw DriveError.remote(code: "E_DRIVER", message: "the app returned no image") }

            if case let .number(maxWidth)? = arguments["maxWidth"], maxWidth > 0,
               let scaled = PNGScaler.fit(png, maxWidth: Int(maxWidth))
            {
                png = scaled
            }
            return [.object([
                "type": .string("image"),
                "data": .string(png.base64EncodedString()),
                "mimeType": .string("image/png")
            ])]
        }
    )

    static let eval = MCPTool(
        name: "app_eval",
        title: "Evaluate JavaScript",
        description: """
        Run JavaScript in the app's page and return the JSON value it evaluates to. This is the \
        app's own JS context, so its globals and its bridge are reachable.
        """,
        inputSchema: object(
            properties: ["js": schema("string", "The expression to evaluate, e.g. document.title.")],
            required: ["js"]
        ),
        run: { client, arguments, options in
            guard let js = arguments["js"]?.stringValue else {
                throw DriveError.remote(code: "E_ARGS", message: "app_eval needs `js`")
            }
            var payload: [String: BridgeJSON] = ["js": .string(js)]
            if let window = options.window { payload["window"] = .string(window) }
            return try [text(client.invoke("eval", payload).prettyPrinted)]
        }
    )

    static let windows = MCPTool(
        name: "app_windows",
        title: "List windows",
        description: "The app's open windows with their ids, titles, sizes and positions.",
        inputSchema: object(),
        run: { client, _, _ in try [text(client.invoke("window.list").prettyPrinted)] }
    )

    static let capabilities = MCPTool(
        name: "app_capabilities",
        title: "What this backend supports",
        description: """
        What this app's backend can actually do — screenshots, and which kinds of synthetic input. \
        Worth calling before clicking or typing: on some backends input isn't available at all, and \
        a request that can't be honoured is refused rather than silently downgraded.
        """,
        inputSchema: object(),
        run: { client, _, _ in try [text(client.invoke("capabilities").prettyPrinted)] }
    )

    // MARK: Acting

    static let click = MCPTool(
        name: "app_click",
        title: "Click in the page",
        description: """
        A real, trusted click through the app's own event queue — the page sees hit testing, focus \
        and default actions, unlike a DOM event dispatched from app_eval. Prefer `selector`: it \
        survives a layout change, and it's measured and clicked in one step so an animation can't \
        leave you clicking where the element used to be.
        """,
        inputSchema: object(properties: [
            "selector": schema("string", "CSS selector; the first match's centre is clicked."),
            "x": schema("number", "Window-local CSS pixels, if you aren't using a selector."),
            "y": schema("number", "Window-local CSS pixels."),
            "clickCount": schema("integer", "2 for a double-click.")
        ]),
        run: { client, arguments, options in
            let point = try resolvePoint(client, arguments, options)
            var count = 1.0
            if case let .number(value)? = arguments["clickCount"] { count = max(1, value) }
            for phase in ["down", "up"] {
                var payload: [String: BridgeJSON] = [
                    "type": .string(phase), "x": .number(point.x), "y": .number(point.y),
                    "clickCount": .number(count)
                ]
                if let window = options.window { payload["window"] = .string(window) }
                try client.invoke("input.pointer", payload)
            }
            return [text("Clicked at \(Int(point.x)), \(Int(point.y)).")]
        }
    )

    static let typeText = MCPTool(
        name: "app_type",
        title: "Type text",
        description: """
        Type into whatever has focus, one real key event per character, so input handlers fire and \
        the text lands where a user's typing would. Pass `selector` to click an element first.
        """,
        inputSchema: object(
            properties: [
                "text": schema("string", "The text to type."),
                "selector": schema("string", "Click this element first, so the text goes somewhere.")
            ],
            required: ["text"]
        ),
        run: { client, arguments, options in
            guard let value = arguments["text"]?.stringValue, !value.isEmpty else {
                throw DriveError.remote(code: "E_ARGS", message: "app_type needs `text`")
            }
            if arguments["selector"]?.stringValue != nil {
                let point = try resolvePoint(client, arguments, options)
                for phase in ["down", "up"] {
                    var payload: [String: BridgeJSON] = [
                        "type": .string(phase), "x": .number(point.x), "y": .number(point.y)
                    ]
                    if let window = options.window { payload["window"] = .string(window) }
                    try client.invoke("input.pointer", payload)
                }
            }
            for character in value {
                try press(client, key: String(character), text: String(character), options)
            }
            return [text("Typed \(value.count) character\(value.count == 1 ? "" : "s").")]
        }
    )

    static let pressKey = MCPTool(
        name: "app_press_key",
        title: "Press a named key",
        description: "Press a single key by its DOM name — Enter, Tab, Escape, ArrowDown, and so on.",
        inputSchema: object(
            properties: ["key": schema("string", "A DOM KeyboardEvent.key value, e.g. Enter.")],
            required: ["key"]
        ),
        run: { client, arguments, options in
            guard let key = arguments["key"]?.stringValue, !key.isEmpty else {
                throw DriveError.remote(code: "E_ARGS", message: "app_press_key needs `key`")
            }
            try press(client, key: key, text: nil, options)
            return [text("Pressed \(key).")]
        }
    )

    static let scroll = MCPTool(
        name: "app_scroll",
        title: "Scroll the page",
        description: """
        Scroll with a wheel event. Positive amounts scroll the content down and right, matching the \
        DOM's sign convention whatever the platform's native direction.
        """,
        inputSchema: object(
            properties: [
                "amount": schema("number", "Vertical distance in CSS pixels; positive scrolls down."),
                "dx": schema("number", "Horizontal distance in CSS pixels."),
                "selector": schema("string", "Scroll over this element rather than the viewport centre.")
            ],
            required: ["amount"]
        ),
        run: { client, arguments, options in
            guard case let .number(amount)? = arguments["amount"] else {
                throw DriveError.remote(code: "E_ARGS", message: "app_scroll needs a numeric `amount`")
            }
            var dx = 0.0
            if case let .number(value)? = arguments["dx"] { dx = value }
            let point: (x: Double, y: Double)
            if arguments["selector"]?.stringValue != nil {
                point = try resolvePoint(client, arguments, options)
            } else {
                let viewport = try client.viewportSize(window: options.window)
                point = (viewport.width / 2, viewport.height / 2)
            }
            var payload: [String: BridgeJSON] = [
                "x": .number(point.x), "y": .number(point.y),
                "deltaX": .number(dx), "deltaY": .number(amount)
            ]
            if let window = options.window { payload["window"] = .string(window) }
            try client.invoke("input.wheel", payload)
            return [text("Scrolled \(Int(amount)) px vertically.")]
        }
    )

    // MARK: Helpers

    private static func press(
        _ client: DriverClient, key: String, text: String?, _ options: DriveOptions
    ) throws {
        for phase in ["down", "up"] {
            var payload: [String: BridgeJSON] = ["type": .string(phase), "key": .string(key)]
            if let text { payload["text"] = .string(text) }
            if let window = options.window { payload["window"] = .string(window) }
            try client.invoke("input.key", payload)
        }
    }

    private static func resolvePoint(
        _ client: DriverClient, _ arguments: BridgeJSON, _ options: DriveOptions
    ) throws -> (x: Double, y: Double) {
        if let selector = arguments["selector"]?.stringValue {
            return try client.center(of: selector, window: options.window)
        }
        guard case let .number(x)? = arguments["x"], case let .number(y)? = arguments["y"] else {
            throw DriveError.remote(
                code: "E_ARGS",
                message: "give a `selector`, or both `x` and `y`"
            )
        }
        return (x, y)
    }

    private static func text(_ value: String) -> BridgeJSON {
        .object(["type": .string("text"), "text": .string(value)])
    }

    private static func schema(_ type: String, _ description: String) -> BridgeJSON {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func object(
        properties: [String: BridgeJSON] = [:],
        required: [String] = []
    ) -> BridgeJSON {
        var schema: [String: BridgeJSON] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }
}

// MARK: - Screenshot scaling

enum PNGScaler {
    /// Downscale a PNG so it's at most `maxWidth` wide, preserving aspect
    /// ratio. Returns nil if it's already narrower, or if the codec is
    /// unavailable — the caller then sends the original rather than nothing.
    ///
    /// Worth doing because a full-resolution capture of a Retina window is
    /// several megabytes, and it arrives base64'd in an agent's context.
    static func fit(_ png: Data, maxWidth: Int) -> Data? {
        #if canImport(CStbImage)
            var width: Int32 = 0
            var height: Int32 = 0
            let decoded: UnsafeMutablePointer<UInt8>? = png.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return swiftpwa_decode_image_rgba(base, Int32(png.count), &width, &height)
            }
            guard let decoded, width > 0, height > 0 else { return nil }
            defer { swiftpwa_free_image(decoded) }

            let sourceWidth = Int(width)
            let sourceHeight = Int(height)
            guard sourceWidth > maxWidth else { return nil }
            let targetWidth = maxWidth
            let targetHeight = max(1, Int((Double(sourceHeight) * Double(maxWidth) / Double(sourceWidth)).rounded()))

            let source = Array(UnsafeBufferPointer(start: decoded, count: sourceWidth * sourceHeight * 4))
            let scaled = WindowsIcon.downscaleRGBA(
                source, srcW: sourceWidth, srcH: sourceHeight,
                dstW: targetWidth, dstH: targetHeight
            )
            return encode(rgba: scaled, width: targetWidth, height: targetHeight)
        #else
            _ = (png, maxWidth)
            return nil
        #endif
    }

    /// Encode raw RGBA bytes as a PNG.
    static func encode(rgba: [UInt8], width: Int, height: Int) -> Data? {
        #if canImport(CStbImage)
            var length: Int32 = 0
            let encoded: UnsafeMutablePointer<UInt8>? = rgba.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return nil }
                return swiftpwa_encode_png_rgba(base, Int32(width), Int32(height), &length)
            }
            guard let encoded, length > 0 else { return nil }
            defer { swiftpwa_free_png(encoded) }
            return Data(bytes: encoded, count: Int(length))
        #else
            _ = (rgba, width, height)
            return nil
        #endif
    }
}
