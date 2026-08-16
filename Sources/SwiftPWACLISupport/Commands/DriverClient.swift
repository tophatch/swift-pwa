import Foundation
import SwiftPWACore

/// This module has its own `JSONValue` — the `pwa.json` `info_plist`
/// passthrough — so the bridge's is named explicitly rather than left to
/// lookup order.
typealias BridgeJSON = SwiftPWACore.JSONValue

#if canImport(Darwin) || canImport(Glibc) || canImport(WinSDK)

    /// Client half of the app driver's control channel — the CLI's end of the
    /// loopback socket an app opens when `SWIFT_PWA_DRIVE` is set.
    ///
    /// Blocking on purpose: this runs in a one-shot CLI where a synchronous
    /// request/response loop is the whole story, and it keeps the wire format
    /// (newline-delimited JSON) readable in a packet dump or a `nc` session.
    final class DriverClient {
        private let socket: SocketHandle
        private let token: String
        private var pending = [UInt8]()
        private var nextID = 1

        init(port: UInt16, token: String) throws {
            LoopbackSocket.startup()
            let socket = LoopbackSocket.makeStreamSocket()
            guard LoopbackSocket.isValid(socket) else {
                throw DriveError.connect("couldn't create a socket")
            }
            guard LoopbackSocket.connectLoopback(socket, port: port) else {
                LoopbackSocket.closeSocket(socket)
                throw DriveError.connect("couldn't connect to 127.0.0.1:\(port)")
            }
            self.socket = socket
            self.token = token
        }

        deinit { LoopbackSocket.closeSocket(socket) }

        /// Send one verb and return its result, turning an error response into
        /// a thrown `DriveError` so callers read as straight-line code.
        @discardableResult
        func invoke(_ cmd: String, _ payload: [String: BridgeJSON] = [:]) throws -> BridgeJSON {
            var frame: [String: BridgeJSON] = [
                "id": .number(Double(nextID)),
                "token": .string(token),
                "cmd": .string(cmd)
            ]
            if !payload.isEmpty { frame["payload"] = .object(payload) }
            nextID += 1

            var line = try [UInt8](BridgeJSON.object(frame).encoded())
            line.append(UInt8(ascii: "\n"))
            guard LoopbackSocket.sendAll(socket, line, offset: 0, count: line.count) else {
                throw DriveError.connect("the app closed the control socket")
            }

            let response = try BridgeJSON.decode(readLine())
            if case .bool(true) = response["ok"] {
                return response["result"] ?? .null
            }
            let code = response["error"]?["code"]?.stringValue ?? "E_DRIVER"
            let message = response["error"]?["message"]?.stringValue ?? "the app rejected the request"
            throw DriveError.remote(code: code, message: message)
        }

        /// Poll `expression` until it evaluates truthy, or give up.
        ///
        /// Client-side by design: a `wait` verb in the app would buy nothing but
        /// round-trips, and would make every tweak to its semantics an
        /// app-binary change.
        func wait(for expression: String, timeout: TimeInterval, window: String?) throws {
            let deadline = Date().addingTimeInterval(timeout)
            var lastError: String?
            repeat {
                do {
                    var payload: [String: BridgeJSON] = ["js": .string("!!(\(expression))")]
                    if let window { payload["window"] = .string(window) }
                    if try invoke("eval", payload).isTruthy { return }
                    lastError = nil
                } catch let DriveError.remote(_, message) {
                    // A page mid-navigation can fail an eval outright; that's a
                    // "not yet", not a failure, until the deadline passes.
                    lastError = message
                }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline

            throw DriveError.timedOut(
                expression: expression,
                seconds: timeout,
                lastError: lastError
            )
        }

        /// Evaluate `script`, and if it produced a thenable, wait for it to
        /// settle and return the settled value.
        ///
        /// Client-side for the same reason `wait` is: it's a polling loop over
        /// the existing `eval` verb, so it needs no app-binary change and works
        /// on every backend. That matters because *no* backend awaits a promise
        /// natively — Apple's `evaluateJavaScript`, WebKitGTK, WebView2 and
        /// Android's WebView all hand the `Promise` object back, which then
        /// fails to serialize.
        ///
        /// The script is run through **indirect `eval`** rather than wrapped in
        /// parentheses, so it stays a *program* and keeps today's semantics
        /// exactly: statements still work, `var` still lands on the global, and
        /// the value is the program's completion value (`a = 1; b = 2` → `2`).
        /// That's what lets this be automatic instead of a flag.
        ///
        /// A page whose CSP forbids `unsafe-eval` can't be driven this way, so
        /// it reports back and the caller falls back to a plain `eval`. The
        /// probe that detects it evaluates a harmless constant *before* the
        /// script, so a page that blocks `eval` never runs the script at all —
        /// the fallback can't double-execute it.
        func evalAwaitingPromise(
            _ script: String,
            timeout: TimeInterval,
            window: String?
        ) throws -> BridgeJSON? {
            let key = "__swiftPWADriveAwait\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let start = """
            (function () {
                var k = \(Self.jsStringLiteral(key));
                try { (0, eval)("0"); } catch (probe) { return { cspBlocked: true }; }
                var v = (0, eval)(\(Self.jsStringLiteral(script)));
                if (!v || typeof v.then !== "function") {
                    return { settled: true, value: v === undefined ? null : v };
                }
                window[k] = { state: "pending" };
                v.then(
                    function (r) { window[k] = { state: "done", value: r === undefined ? null : r }; },
                    function (e) {
                        window[k] = { state: "failed", message: String(e && e.message ? e.message : e) };
                    }
                );
                return { settled: false };
            })()
            """

            var payload: [String: BridgeJSON] = ["js": .string(start)]
            if let window { payload["window"] = .string(window) }
            let first = try invoke("eval", payload)
            // nil means "this page forbids eval" — the caller runs the script
            // the old way. Nothing of it has executed yet.
            if case .bool(true) = first["cspBlocked"] { return nil }
            if case .bool(true) = first["settled"] { return first["value"] ?? .null }

            // Drain the global as we read it, so a page driven repeatedly
            // doesn't accumulate one leaked key per awaited call.
            let poll = """
            (function () {
                var k = \(Self.jsStringLiteral(key));
                var s = window[k];
                if (!s) { return { state: "lost" }; }
                if (s.state === "pending") { return { state: "pending" }; }
                delete window[k];
                return s;
            })()
            """
            var pollPayload: [String: BridgeJSON] = ["js": .string(poll)]
            if let window { pollPayload["window"] = .string(window) }

            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let state = try invoke("eval", pollPayload)
                switch state["state"]?.stringValue {
                case "done":
                    return state["value"] ?? .null
                case "failed":
                    throw DriveError.remote(
                        code: "E_EVAL_REJECTED",
                        message: state["message"]?.stringValue ?? "the awaited promise rejected"
                    )
                case "lost":
                    // The page navigated out from under us and took the global
                    // with it; there is nothing left to wait for.
                    throw DriveError.remote(
                        code: "E_EVAL_LOST",
                        message: "the page navigated while the awaited promise was still pending"
                    )
                default:
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            } while Date() < deadline

            throw DriveError.timedOut(
                expression: script,
                seconds: timeout,
                lastError: "the script returned a promise that never settled"
            )
        }

        /// A JS string literal for `value`, so a key or script can't end the
        /// literal early or inject.
        static func jsStringLiteral(_ value: String) -> String {
            var out = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\u{2028}": out += "\\u2028"
                case "\u{2029}": out += "\\u2029"
                default:
                    if scalar.value < 0x20 {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out + "\""
        }

        /// The centre of the first element matching `selector`, in the same
        /// window-local CSS pixels the `input.*` verbs take.
        ///
        /// Client-side on purpose, like `wait`: it's `getBoundingClientRect`
        /// arithmetic over `eval`, and putting it in the app would make every
        /// tweak to "where exactly do we click" an app-binary change.
        func center(of selector: String, window: String?) throws -> (x: Double, y: Double) {
            // Encode the selector as a JS string literal so a quote or
            // backslash in it can't break out of the snippet.
            let encoder = JSONEncoder()
            let literal = try String(data: encoder.encode(selector), encoding: .utf8) ?? "\"\""
            var payload: [String: BridgeJSON] = ["js": .string("""
            (() => {
              const el = document.querySelector(\(literal));
              if (!el) return null;
              const r = el.getBoundingClientRect();
              if (!r.width || !r.height) return { empty: true };
              return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
            })()
            """)]
            if let window { payload["window"] = .string(window) }
            let result = try invoke("eval", payload)

            if case .bool(true) = result["empty"] {
                throw DriveError.remote(
                    code: "E_DRIVER_TARGET",
                    message: "'\(selector)' matched an element with no size — is it hidden?"
                )
            }
            guard case let .number(x)? = result["x"], case let .number(y)? = result["y"] else {
                throw DriveError.remote(
                    code: "E_DRIVER_TARGET",
                    message: "nothing matched '\(selector)'"
                )
            }
            return (x, y)
        }

        /// The viewport's CSS-pixel size, for `--fraction` coordinates.
        func viewportSize(window: String?) throws -> (width: Double, height: Double) {
            var payload: [String: BridgeJSON] = ["js": .string("({w: innerWidth, h: innerHeight})")]
            if let window { payload["window"] = .string(window) }
            let result = try invoke("eval", payload)
            guard case let .number(width)? = result["w"], case let .number(height)? = result["h"] else {
                throw DriveError.remote(code: "E_DRIVER_TARGET", message: "couldn't read the viewport size")
            }
            return (width, height)
        }

        private func readLine() throws -> Data {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = Array(pending[pending.startIndex ..< newline])
                    pending.removeSubrange(pending.startIndex ... newline)
                    return Data(line)
                }
                let n = LoopbackSocket.recvInto(socket, &buffer)
                guard n > 0 else {
                    throw DriveError.connect("the app closed the control socket mid-response")
                }
                pending.append(contentsOf: buffer[0 ..< n])
            }
        }
    }

#endif

/// Outside the platform gate above: the socket client needs Darwin / Glibc /
/// WinSDK, but reading and printing JSON doesn't, and the agent-surface commands
/// use these wherever the CLI builds.
extension SwiftPWACore.JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// JS truthiness, applied to whatever the backend's `eval` handed
    /// back. Lenient on purpose: a backend that reports a JS `true` as the
    /// number `1` should still satisfy a `--wait`.
    var isTruthy: Bool {
        switch self {
        case let .bool(value): value
        case let .number(value): value != 0
        case let .string(value): !value.isEmpty
        case let .array(items): !items.isEmpty
        case .object: true
        case .null: false
        }
    }

    /// Pretty JSON for printing a verb's result to a terminal.
    var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "<unprintable>" }
        return text
    }
}
