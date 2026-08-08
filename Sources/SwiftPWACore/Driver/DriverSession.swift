#if SWIFT_PWA_DRIVER

    import Foundation

    /// Verb dispatch for the app driver's control channel — the half that has
    /// nothing to do with sockets, so it can be unit-tested against a
    /// `MockAppContext` without binding a port.
    ///
    /// One request in, one response out, newline-delimited JSON:
    ///
    /// ```text
    /// → {"id":1,"token":"…","cmd":"eval","payload":{"js":"document.title"}}
    /// ← {"id":1,"ok":true,"result":"CritterFacts"}
    /// ```
    ///
    /// The verb set is deliberately small. `wait`, viewport-fraction clicks and
    /// retry loops belong to the *client*: putting them here would buy nothing
    /// but round-trips, and would make every tweak to their semantics an
    /// app-binary change.
    ///
    /// **Not `@MainActor`.** Every window touch hops through ``MainThread/run``
    /// instead, for the reason documented on that type: under `gtk_main()`
    /// Swift's main-actor executor is never drained, so a `@MainActor` method
    /// awaited from the driver's socket thread would hang forever on Linux.
    final class DriverSession: Sendable {
        /// Bumped when a frame's shape changes incompatibly, so a mismatched
        /// CLI can say so instead of failing obscurely.
        static let protocolVersion = 1

        private let context: any AppContext
        private let token: String
        private let backend: String

        init(context: any AppContext, token: String, backend: String) {
            self.context = context
            self.token = token
            self.backend = backend
        }

        // MARK: - Entry point

        /// Handle one raw request line and return the response line's bytes
        /// (no trailing newline). Never throws — a malformed frame is answered
        /// with an error response, because the socket loop has no better way to
        /// report it than the channel it came in on.
        func handle(line: Data) async -> Data {
            let request: DriverRequest
            do {
                request = try JSONDecoder().decode(DriverRequest.self, from: line)
            } catch {
                return Self.encode(DriverResponse(
                    id: nil,
                    error: DriverError.badRequest("not a JSON control frame: \(error)")
                ))
            }

            // Constant-time comparison isn't warranted — the token guards a
            // loopback port on a dev build against other local processes, not a
            // network service against an attacker who can time it.
            guard request.token == token else {
                return Self.encode(DriverResponse(
                    id: request.id,
                    error: DriverError.auth("missing or incorrect token")
                ))
            }

            do {
                let result = try await dispatch(request)
                return Self.encode(DriverResponse(id: request.id, result: result))
            } catch let error as BridgeError {
                return Self.encode(DriverResponse(id: request.id, error: error))
            } catch {
                return Self.encode(DriverResponse(
                    id: request.id,
                    error: BridgeError(code: BridgeError.handler, message: "\(error)")
                ))
            }
        }

        // MARK: - Verbs

        private func dispatch(_ request: DriverRequest) async throws -> JSONValue {
            switch request.cmd {
            case "capabilities": await capabilities()
            case "window.list": await windowList()
            case "eval": try await eval(request.payload)
            case "screenshot": try await screenshot(request.payload)
            case "window.setSize": try await setSize(request.payload)
            case "window.setPosition": try await setPosition(request.payload)
            default:
                throw DriverError.unknownCommand(request.cmd)
            }
        }

        /// What this backend can actually do. Load-bearing rather than a
        /// nicety: native input synthesis and webview snapshots are genuinely
        /// absent on some backends, and a client that assumes otherwise writes
        /// tests that pass by not running.
        private func capabilities() async -> JSONValue {
            let verbs: [JSONValue] = [
                "capabilities", "window.list", "eval",
                "screenshot", "window.setSize", "window.setPosition"
            ].map { .string($0) }

            let context = context
            let probe: (count: Int, snapshot: Bool?) = await MainThread.run {
                // Snapshot support is a property of the webview, so read it off
                // a live one. With no windows open there is nothing to ask.
                let first = context.windows.sorted { $0.key.raw < $1.key.raw }.first?.value
                return (context.windows.count, first?.webView.supportsSnapshot)
            }

            return .object([
                "protocol": .number(Double(Self.protocolVersion)),
                "backend": .string(backend),
                "verbs": .array(verbs),
                "screenshot": probe.snapshot.map { JSONValue.bool($0) } ?? .null,
                // Cut 1 ships no native input synthesis on any backend; drive
                // the DOM through `eval` in the meantime.
                "input": .bool(false),
                "windows": .number(Double(probe.count))
            ])
        }

        private func windowList() async -> JSONValue {
            let context = context
            return await MainThread.run {
                .array(Self.ordered(context).map { window in
                    .object([
                        "id": .string(window.id.raw),
                        "title": .string(window.title()),
                        "size": .object([
                            "width": .number(window.size().width),
                            "height": .number(window.size().height)
                        ]),
                        "position": .object([
                            "x": .number(window.position().x),
                            "y": .number(window.position().y)
                        ]),
                        "fullscreen": .bool(window.isFullscreen())
                    ])
                })
            }
        }

        private func eval(_ payload: JSONValue?) async throws -> JSONValue {
            guard case let .string(js)? = payload?["js"], !js.isEmpty else {
                throw DriverError.badRequest("eval needs a non-empty `js` string")
            }
            let raw = try await resolveWebView(payload).evaluateJavaScript(js)
            guard let raw else { return .null }
            // Backends return the JSON serialization of the JS value. If it
            // doesn't parse, the backend handed back a bare string — surface it
            // as one rather than failing the call.
            guard let parsed = try? JSONValue.decode(Data(raw.utf8)) else {
                return .string(raw)
            }
            return parsed
        }

        private func screenshot(_ payload: JSONValue?) async throws -> JSONValue {
            let webView = try await resolveWebView(payload)
            guard webView.supportsSnapshot else {
                throw DriverError.unsupported(
                    "screenshot isn't implemented on the \(backend) backend"
                )
            }
            let png = try await webView.captureSnapshot()
            return .object([
                "pngBase64": .string(png.base64EncodedString()),
                "bytes": .number(Double(png.count))
            ])
        }

        private func setSize(_ payload: JSONValue?) async throws -> JSONValue {
            guard case let .number(width)? = payload?["width"],
                  case let .number(height)? = payload?["height"]
            else {
                throw DriverError.badRequest("window.setSize needs numeric `width` and `height`")
            }
            let context = context
            return try await MainThread.run {
                let window = try Self.resolve(payload, in: context)
                window.setSize(Size(width: width, height: height), animated: false)
                // Read back rather than echo: `setSize` is best-effort on
                // backends whose window manager owns geometry.
                let actual = window.size()
                return .object([
                    "width": .number(actual.width),
                    "height": .number(actual.height)
                ])
            }
        }

        private func setPosition(_ payload: JSONValue?) async throws -> JSONValue {
            guard case let .number(x)? = payload?["x"], case let .number(y)? = payload?["y"] else {
                throw DriverError.badRequest("window.setPosition needs numeric `x` and `y`")
            }
            let context = context
            return try await MainThread.run {
                let window = try Self.resolve(payload, in: context)
                window.setPosition(Point(x: x, y: y))
                // Same best-effort caveat as `setSize`, and more so: GTK4 and
                // Wayland silently refuse to move a window at all.
                let actual = window.position()
                return .object(["x": .number(actual.x), "y": .number(actual.y)])
            }
        }

        // MARK: - Helpers

        /// The target window's webview. Returned out of the main thread on
        /// purpose: `PWAWebView` is deliberately *not* main-actor isolated (each
        /// backend hops internally), so `evaluateJavaScript` / `captureSnapshot`
        /// can then run without holding up the UI thread.
        private func resolveWebView(_ payload: JSONValue?) async throws -> any PWAWebView {
            let context = context
            return try await MainThread.run {
                try Self.resolve(payload, in: context).webView
            }
        }

        /// Windows in a stable order, so `window.list[0]` means the same thing
        /// across two calls in one session (the dictionary's order doesn't).
        @MainActor
        private static func ordered(_ context: any AppContext) -> [any Window] {
            context.windows.sorted { $0.key.raw < $1.key.raw }.map(\.value)
        }

        /// The window a verb applies to: the one named by `window`, or the only
        /// one open. Ambiguity is an error rather than a guess — silently
        /// driving the wrong window is the failure mode that makes a driver
        /// worse than useless.
        @MainActor
        private static func resolve(_ payload: JSONValue?, in context: any AppContext) throws -> any Window {
            if case let .string(id)? = payload?["window"] {
                guard let window = context.window(WindowID(raw: id)) else {
                    throw DriverError.noWindow("no window with id \(id)")
                }
                return window
            }
            let windows = ordered(context)
            switch windows.count {
            case 0: throw DriverError.noWindow("the app has no open windows")
            case 1: return windows[0]
            default:
                let ids = windows.map(\.id.raw).joined(separator: ", ")
                throw DriverError.noWindow(
                    "\(windows.count) windows are open — name one with `window`: \(ids)"
                )
            }
        }

        private static func encode(_ response: DriverResponse) -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(response) { return data }
            // Encoding our own response type can only fail on a non-finite
            // Double reaching us from a window's geometry. Say so on the wire
            // rather than dropping the frame and hanging the client.
            return Data(#"{"ok":false,"error":{"code":"E_DRIVER_ENCODE","message":"unencodable result"}}"#.utf8)
        }
    }

    // MARK: - Wire types

    struct DriverRequest: Decodable {
        var id: Int?
        var token: String?
        var cmd: String
        var payload: JSONValue?
    }

    struct DriverResponse: Encodable {
        var id: Int?
        var ok: Bool
        var result: JSONValue?
        var error: BridgeError?

        init(id: Int?, result: JSONValue) {
            self.id = id
            ok = true
            self.result = result
            error = nil
        }

        init(id: Int?, error: BridgeError) {
            self.id = id
            ok = false
            result = nil
            self.error = error
        }
    }

    /// Driver-specific failures. Separate codes from the bridge's own so a
    /// client can tell "your control frame was wrong" from "the app's command
    /// handler threw".
    enum DriverError {
        static func auth(_ message: String) -> BridgeError {
            BridgeError(code: "E_DRIVER_AUTH", message: message)
        }

        static func badRequest(_ message: String) -> BridgeError {
            BridgeError(code: "E_DRIVER_REQUEST", message: message)
        }

        static func unknownCommand(_ cmd: String) -> BridgeError {
            BridgeError(code: "E_DRIVER_COMMAND", message: "unknown driver command '\(cmd)'")
        }

        static func noWindow(_ message: String) -> BridgeError {
            BridgeError(code: "E_DRIVER_WINDOW", message: message)
        }

        static func unsupported(_ message: String) -> BridgeError {
            BridgeError(code: "E_DRIVER_UNSUPPORTED", message: message)
        }
    }

    extension JSONValue {
        /// Read a key off an object value, so payload access reads as
        /// `payload?["js"]` instead of a `case .object` dance at every call.
        subscript(key: String) -> JSONValue? {
            guard case let .object(fields) = self else { return nil }
            return fields[key]
        }
    }

#endif
