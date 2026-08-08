import Foundation
import SwiftPWACore

/// This module has its own `JSONValue` — the `pwa.json` `info_plist`
/// passthrough — so the bridge's is named explicitly rather than left to
/// lookup order.
typealias DriverJSON = SwiftPWACore.JSONValue

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
        func invoke(_ cmd: String, _ payload: [String: DriverJSON] = [:]) throws -> DriverJSON {
            var frame: [String: DriverJSON] = [
                "id": .number(Double(nextID)),
                "token": .string(token),
                "cmd": .string(cmd)
            ]
            if !payload.isEmpty { frame["payload"] = .object(payload) }
            nextID += 1

            var line = try [UInt8](DriverJSON.object(frame).encoded())
            line.append(UInt8(ascii: "\n"))
            guard LoopbackSocket.sendAll(socket, line, offset: 0, count: line.count) else {
                throw DriveError.connect("the app closed the control socket")
            }

            let response = try DriverJSON.decode(readLine())
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
                    var payload: [String: DriverJSON] = ["js": .string("!!(\(expression))")]
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

    extension SwiftPWACore.JSONValue {
        subscript(key: String) -> DriverJSON? {
            guard case let .object(fields) = self else { return nil }
            return fields[key]
        }

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

#endif
