import Foundation

/// A one-flow HTTP listener on `127.0.0.1` that catches an OAuth redirect.
///
/// **Why it isn't ``LoopbackServer``.** That one frames NDJSON and serves two
/// long-lived consumers (the app driver and the agent surface). This one speaks
/// just enough HTTP to read a request line and answer a page, and it exists for
/// the length of one sign-in. Giving `LoopbackServer` an HTTP mode would put a
/// branch in the hot path of two things that never take it. What *is* shared is
/// ``LoopbackSocket`` — bind, listen, poll, accept, recv, send across BSD
/// sockets and Winsock — so the new code here is request parsing, not sockets.
///
/// **`127.0.0.1`, never `localhost`.** The name can resolve to `::1` first, and
/// an IPv4-bound listener then never hears the browser at all. The failure mode
/// is a sign-in that hangs until the timeout with the consent page showing
/// success, which is about as confusing as this gets.
///
/// **It accepts repeatedly.** Browsers open speculative connections and ask for
/// `/favicon.ico`; a receiver that stopped after the first connection would lose
/// the real callback roughly as often as it caught it. Anything that isn't the
/// redirect path gets a 404 and the loop keeps going.
package final class LoopbackRedirectReceiver: @unchecked Sendable {
    /// The port the OS assigned. Google's desktop client type accepts any port
    /// on loopback, which is what lets this work with nothing registered.
    package let port: UInt16

    /// The path the redirect URI names (everything else 404s).
    package let path: String

    /// `http://127.0.0.1:<port><path>` — what goes to the provider as
    /// `redirect_uri` and what the token exchange has to repeat verbatim.
    package var redirectURI: String {
        "http://127.0.0.1:\(port)\(path)"
    }

    private let listener: SocketHandle
    private let lock = NSLock()
    private var stopping = false
    /// Whether the accept loop has taken ownership of the listener. It closes
    /// the socket on its way out; before it starts, `stop()` has to.
    private var accepting = false

    /// Bind and start listening. Throws `E_AUTH_REDIRECT` if the socket can't
    /// be had — which on a locked-down machine is a real answer the caller
    /// should show, not something to retry.
    package init(path: String = "/callback") throws {
        LoopbackSocket.startup()

        let socket = LoopbackSocket.makeStreamSocket()
        guard LoopbackSocket.isValid(socket) else {
            throw BridgeError(code: BridgeError.authRedirect, message: "couldn't create a loopback socket")
        }
        // Deliberately no SO_REUSEADDR: the port is OS-assigned and one flow
        // long, so the only thing reuse could do here is let a second flow bind
        // a port a first one is still listening on.
        guard LoopbackSocket.bindLoopback(socket, port: 0) else {
            LoopbackSocket.closeSocket(socket)
            throw BridgeError(code: BridgeError.authRedirect, message: "couldn't bind 127.0.0.1 for the redirect")
        }
        guard LoopbackSocket.startListening(socket, backlog: 4) else {
            LoopbackSocket.closeSocket(socket)
            throw BridgeError(code: BridgeError.authRedirect, message: "couldn't listen on 127.0.0.1")
        }

        listener = socket
        port = LoopbackSocket.boundPort(socket)
        self.path = path
    }

    /// Belt and braces for the caller that drops the receiver without ever
    /// awaiting it. The accept loop retains `self` strongly for its whole life,
    /// so this can only run when no loop is in flight — which is exactly the
    /// case where nobody else would close the socket.
    deinit { stop() }

    /// Wait for a callback whose `state` matches, up to `timeout` seconds.
    ///
    /// A callback with a **wrong or missing `state` is answered, dropped, and
    /// the wait continues** — a mismatch is either an attack or an unrelated
    /// local request, and neither should end a flow the user is still in the
    /// middle of.
    ///
    /// Runs the blocking accept loop on a detached thread (it parks in `poll`,
    /// which would tie up a cooperative-pool thread for the whole sign-in) and
    /// bridges it back through a continuation.
    package func waitForCallback(state: String, timeout: TimeInterval) async throws -> AuthorizationCallback {
        let deadline = Date().addingTimeInterval(timeout)
        guard claimListener() else {
            throw BridgeError(code: BridgeError.cancelled, message: "the sign-in was cancelled")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread { [self] in
                    continuation.resume(with: acceptLoop(state: state, deadline: deadline))
                }
            }
        } onCancel: {
            stop()
        }
    }

    /// Hand the listener to the accept loop, unless ``stop()`` already closed
    /// it. Not `async` — `NSLock.lock()` is unavailable from an async context,
    /// and this is called from one.
    private func claimListener() -> Bool {
        lock.withLock {
            guard !stopping else { return false }
            accepting = true
            return true
        }
    }

    /// Stop listening. Idempotent; safe from any thread.
    ///
    /// Once the accept loop is running it owns the socket and closes it on its
    /// way out, so this only sets the flag — closing underneath a thread that is
    /// polling the descriptor risks hitting a recycled one. Before the loop
    /// starts there is nobody to do it, which is the case that matters: binding
    /// succeeds in `init`, so a flow that fails in between (the browser refuses
    /// to open, the external-URL policy says no) would otherwise leak a listening
    /// socket per attempt.
    package func stop() {
        lock.lock()
        let alreadyStopping = stopping
        let loopOwnsIt = accepting
        stopping = true
        lock.unlock()

        if !alreadyStopping, !loopOwnsIt { LoopbackSocket.closeSocket(listener) }
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    // MARK: - The loop

    private func acceptLoop(state: String, deadline: Date) -> Result<AuthorizationCallback, any Error> {
        defer { LoopbackSocket.closeSocket(listener) }

        while true {
            if isStopping {
                return .failure(BridgeError(code: BridgeError.cancelled, message: "the sign-in was cancelled"))
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return .failure(BridgeError(
                    code: BridgeError.authTimeout,
                    message: "no redirect arrived on \(redirectURI) within the timeout"
                ))
            }

            // Poll rather than block in accept, so a cancel or a timeout is
            // noticed without waiting for a connection that may never come.
            let slice = Int32(min(remaining * 1000, 500).rounded(.up))
            let ready = LoopbackSocket.pollReadable(listener, timeoutMs: max(slice, 1))
            if ready < 0 {
                return .failure(BridgeError(code: BridgeError.authRedirect, message: "the redirect listener failed"))
            }
            if ready == 0 { continue }

            let client = LoopbackSocket.acceptOne(listener)
            guard LoopbackSocket.isValid(client) else { continue }
            defer { LoopbackSocket.closeSocket(client) }

            guard let line = readRequest(client) else {
                respond(client, status: "400 Bad Request", body: Self.errorPage)
                continue
            }
            guard let target = Self.requestTarget(line) else {
                respond(client, status: "400 Bad Request", body: Self.errorPage)
                continue
            }
            guard Self.pathComponent(of: target) == path else {
                respond(client, status: "404 Not Found", body: Self.errorPage)
                continue
            }

            let query = Self.queryItems(of: target)
            guard let received = query["state"], PKCE.constantTimeEquals(received, state) else {
                // Answered, then ignored: the person who typed this URL (or the
                // app that sent it) gets an explanation, and the flow the user
                // is actually in keeps waiting.
                respond(client, status: "400 Bad Request", body: Self.mismatchPage)
                continue
            }

            respond(client, status: "200 OK", body: Self.successPage)
            return .success(AuthorizationCallback(parameters: query))
        }
    }

    /// Read the request's **whole header block** and return its first line.
    ///
    /// Only the request line is used — a redirect is a GET, so there is nothing
    /// in the headers this needs. It reads all of them anyway because closing a
    /// socket that still has unread input sends an RST and *discards the
    /// response we just wrote*: stopping at the first CRLF would leave the
    /// browser's headers in the receive buffer and the user looking at a
    /// connection-reset page instead of "you can close this tab". The sign-in
    /// itself would have succeeded, which is what makes it a nasty one to spot.
    ///
    /// The read timeout is short and per-poll because connections are handled
    /// one at a time: a speculative connection that opens and sends nothing
    /// should cost a moment, not the rest of the flow. A real callback that
    /// arrives meanwhile waits in the accept backlog and is served next.
    private func readRequest(_ client: SocketHandle) -> String? {
        var pending = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Headers longer than this are not a browser redirect; the cap is what
        // stops a local process from growing the buffer forever.
        let maximum = 64 * 1024

        while pending.count < maximum {
            if LoopbackSocket.pollReadable(client, timeoutMs: 1000) <= 0 { return nil }
            let n = LoopbackSocket.recvInto(client, &buffer)
            guard n > 0 else { return nil }
            pending.append(contentsOf: buffer[0 ..< n])
            if Self.headersComplete(pending) {
                guard let newline = pending.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
                let line = pending[pending.startIndex ..< newline]
                return String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            }
        }
        return nil
    }

    /// Whether `bytes` contains the end of an HTTP header block. Accepts the
    /// bare-LF spelling as well as CRLF — a hand-typed `nc` request produces
    /// it, and being able to drive this receiver by hand is worth four lines.
    static func headersComplete(_ bytes: [UInt8]) -> Bool {
        let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        guard bytes.count >= 2 else { return false }
        for index in 1 ..< bytes.count where bytes[index] == lf {
            if bytes[index - 1] == lf { return true }
            guard index >= 3, bytes[index - 1] == cr else { continue }
            if bytes[index - 2] == lf, bytes[index - 3] == cr { return true }
        }
        return false
    }

    private func respond(_ client: SocketHandle, status: String, body: String) {
        let payload = Array(body.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(payload.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var bytes = Array(header.utf8)
        bytes.append(contentsOf: payload)
        _ = LoopbackSocket.sendAll(client, bytes, offset: 0, count: bytes.count)
    }

    // MARK: - Request parsing

    /// The request target from a request line — `GET /callback?… HTTP/1.1` →
    /// `/callback?…`. Nil for anything that isn't a well-formed line, and for
    /// any method but GET (a redirect is always a GET; anything else reaching
    /// this socket is not the browser we're waiting for).
    static func requestTarget(_ line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    static func pathComponent(of target: String) -> String {
        String(target.prefix(while: { $0 != "?" && $0 != "#" }))
    }

    /// Percent-decoded query parameters from a request target.
    ///
    /// Hand-rolled rather than via `URLComponents` because the target is a
    /// *relative* reference (`/callback?code=…`), which `URLComponents` parses
    /// inconsistently between Darwin Foundation and swift-corelibs — the kind of
    /// difference that shows up as "works on my Mac" and fails on Linux.
    static func queryItems(of target: String) -> [String: String] {
        guard let mark = target.firstIndex(of: "?") else { return [:] }
        let query = target[target.index(after: mark)...].prefix(while: { $0 != "#" })
        return parseFormEncoded(String(query))
    }

    /// `a=1&b=2` → `["a": "1", "b": "2"]`, with `+` meaning space and `%XX`
    /// decoded. Shared with the custom-scheme receiver so both spell the
    /// decoding the same way.
    static func parseFormEncoded(_ query: String) -> [String: String] {
        var items: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = percentDecode(String(halves[0])), !name.isEmpty else { continue }
            let value = halves.count > 1 ? percentDecode(String(halves[1])) : ""
            items[name] = value ?? ""
        }
        return items
    }

    static func percentDecode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    // MARK: - Pages

    /// Deliberately one self-contained document with no external references.
    /// It renders in a browser tab with no network, no fonts to wait for, and
    /// nothing that could leak the query string it was reached with to a third
    /// party — the URL of this page contains the authorization code.
    ///
    /// `history.replaceState` drops the code from the address bar so it doesn't
    /// end up in the browser's history or a screenshot.
    static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer"><title>\(title)</title>
        <style>
        :root{color-scheme:light dark}
        body{margin:0;min-height:100vh;display:grid;place-items:center;
        font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;
        background:Canvas;color:CanvasText}
        main{max-width:22rem;padding:2rem;text-align:center}
        h1{font-size:1.25rem;font-weight:600;margin:0 0 .5rem}
        p{margin:0;opacity:.7}
        </style></head>
        <body><main><h1>\(title)</h1><p>\(message)</p></main>
        <script>history.replaceState(null,"",location.pathname)</script>
        </body></html>
        """
    }

    static let successPage = page(
        title: "Signed in",
        message: "You can close this tab and go back to the app."
    )

    static let mismatchPage = page(
        title: "Couldn’t complete sign-in",
        message: "This link didn’t match the sign-in the app is waiting for. Start again from the app."
    )

    static let errorPage = page(
        title: "Nothing here",
        message: "This address only handles a sign-in redirect."
    )
}

/// The query parameters of a redirect, whichever receiver caught it.
package struct AuthorizationCallback: Equatable {
    package var parameters: [String: String]

    package init(parameters: [String: String]) {
        self.parameters = parameters
    }
}
