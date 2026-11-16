import Foundation

/// Serves an ``AssetProvider`` over plain HTTP on `127.0.0.1`, for the one
/// consumer that can't read the app's own `pwa://` scheme: WebKitGTK's media
/// player (#349).
///
/// WebKitGTK plays `<video>` and `<audio>` through GStreamer, and the source
/// element it hands GStreamer accepts `http`, `https` and `blob` only. A URI
/// scheme registered with `webkit_web_context_register_uri_scheme` serves
/// `fetch` and `<img>` but never reaches a media element, and nothing an
/// embedder ships can widen that list. So the GTK backends start one of these
/// and `bridge.js` points the page's media URLs at it. Measured on WebKitGTK
/// 2.52 under both GTK3 and GTK4: `pwa://` and `file://` fail with
/// `MEDIA_ERR_SRC_NOT_SUPPORTED`, loopback `http://` plays and seeks.
///
/// What it answers is exactly what the scheme handler answers: the same
/// provider, so the bundle and every `serveDirectory` mount (including one
/// added after launch), and the same `Range` handling (``ByteRange``), so a
/// large clip streams off disk instead of being read whole.
///
/// **Access.** A loopback port is reachable by every process on the machine
/// and by every web page in every browser on it, so each request must carry
/// the per-launch token as its first path segment, and the `Host` must be the
/// address this server bound (a DNS-rebound name can't present it). Only
/// `GET` and `HEAD` exist. CORS answers the app's own origin only, so a frame
/// drawn from a `crossorigin` video stays readable to the app and to nobody
/// else.
///
/// One thread per connection, and `Connection: close` after every response:
/// a media player opens several connections at once and abandons one on
/// every seek, and a connection that lives for one response is all that
/// takes. A client that stops reading (a paused video whose buffer is full)
/// simply parks its thread in `send` until it reads again or hangs up.
package final class LoopbackMediaServer: @unchecked Sendable {
    /// `http://127.0.0.1:<port>/<token>/` — a path under it names the same
    /// file as that path under `pwa://localhost/`.
    package let baseURL: String

    private let listener: SocketHandle
    private let port: UInt16
    private let token: String
    private let provider: AssetProvider
    private let allowedOrigin: String
    private let lock = NSLock()
    private var stopping = false

    /// Headers past this are refused rather than buffered; a media request's
    /// headers are a few hundred bytes.
    private static let headerLimit = 16 * 1024
    /// How long a connection may take to send its request. Bounds the thread
    /// a client that connects and says nothing would otherwise hold forever.
    private static let requestTimeoutMs: Int32 = 10000
    private static let bodyChunk = 256 * 1024

    /// Bind an OS-chosen port and start accepting.
    package static func start(provider: AssetProvider) throws -> LoopbackMediaServer {
        LoopbackSocket.startup()
        let listener = LoopbackSocket.makeStreamSocket()
        guard LoopbackSocket.isValid(listener) else {
            throw LoopbackServerError.socket("socket() failed")
        }
        guard LoopbackSocket.bindLoopback(listener, port: 0) else {
            LoopbackSocket.closeSocket(listener)
            throw LoopbackServerError.socket("couldn't bind 127.0.0.1")
        }
        guard LoopbackSocket.startListening(listener, backlog: 16) else {
            LoopbackSocket.closeSocket(listener)
            throw LoopbackServerError.socket("listen() failed")
        }
        let server = LoopbackMediaServer(
            listener: listener,
            port: LoopbackSocket.boundPort(listener),
            token: LoopbackServer.makeToken(),
            provider: provider
        )
        // A dedicated OS thread: the loop blocks in poll/accept, which would
        // starve a cooperative-pool thread.
        Thread.detachNewThread { server.acceptLoop() }
        return server
    }

    private init(listener: SocketHandle, port: UInt16, token: String, provider: AssetProvider) {
        self.listener = listener
        self.port = port
        self.token = token
        self.provider = provider
        allowedOrigin = "\(provider.scheme)://\(provider.host)"
        baseURL = "http://127.0.0.1:\(port)/\(token)/"
    }

    /// Stop accepting. Responses already being written finish.
    package func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func acceptLoop() {
        while !isStopping {
            let ready = LoopbackSocket.pollReadable(listener, timeoutMs: 500)
            if ready < 0 { break }
            if ready == 0 { continue }
            let client = LoopbackSocket.acceptOne(listener)
            guard LoopbackSocket.isValid(client) else { continue }
            Thread.detachNewThread { [self] in
                serve(client)
                LoopbackSocket.closeSocket(client)
            }
        }
        LoopbackSocket.closeSocket(listener)
    }

    // MARK: - One connection

    private func serve(_ client: SocketHandle) {
        guard let head = readHead(client) else { return }
        let response = respond(to: head)
        var out = [UInt8](response.head.utf8)
        guard LoopbackSocket.sendAll(client, out, offset: 0, count: out.count) else { return }
        guard let body = response.body else { return }
        guard let handle = try? FileHandle(forReadingFrom: body.file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(body.offset))
            var remaining = body.length
            while remaining > 0 {
                let want = Int(min(Int64(Self.bodyChunk), remaining))
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { return }
                out = [UInt8](chunk)
                // A failed send is the player hanging up — on a seek, every time.
                guard LoopbackSocket.sendAll(client, out, offset: 0, count: out.count) else { return }
                remaining -= Int64(chunk.count)
            }
        } catch {
            return
        }
    }

    /// The request line and headers, or nil for a client that sends nothing
    /// usable in time.
    private func readHead(_ client: SocketHandle) -> String? {
        var pending = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator: [UInt8] = [13, 10, 13, 10]
        while pending.count < Self.headerLimit {
            guard LoopbackSocket.pollReadable(client, timeoutMs: Self.requestTimeoutMs) > 0 else { return nil }
            let n = LoopbackSocket.recvInto(client, &buffer)
            guard n > 0 else { return nil }
            pending.append(contentsOf: buffer[0 ..< n])
            if let end = Self.find(terminator, in: pending) {
                return String(decoding: pending[0 ..< end], as: UTF8.self)
            }
        }
        return nil
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for i in 0 ... (haystack.count - needle.count) where haystack[i ..< i + needle.count].elementsEqual(needle) {
            return i
        }
        return nil
    }

    struct Response {
        var head: String
        var body: (file: URL, offset: Int64, length: Int64)?
    }

    /// Answer one request head. Pure apart from the provider's filesystem
    /// lookup, so it's tested without a socket.
    func respond(to head: String) -> Response {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return Self.status(400, "Bad Request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        // Neither a wrong token nor a foreign Host learns anything — the same
        // 404 as a file that isn't there.
        guard headers["host"] == "127.0.0.1:\(port)" else { return Self.status(404, "Not Found") }
        let prefix = "/\(token)/"
        let target = String(parts[1])
        guard target.hasPrefix(prefix) else { return Self.status(404, "Not Found") }

        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            return Self.status(405, "Method Not Allowed", extra: ["Allow: GET, HEAD"])
        }

        let path = target.dropFirst(prefix.count).prefix { $0 != "?" && $0 != "#" }
        guard let url = URL(string: "\(allowedOrigin)/\(path)"),
              let resolved = provider.resolve(url)
        else { return Self.status(404, "Not Found") }

        var common = [
            "Accept-Ranges: bytes",
            // The pwa:// answer is never cached, and a copy of every clip in
            // WebKit's disk cache would outlive a pack being replaced.
            "Cache-Control: no-store"
        ]
        if headers["origin"] == allowedOrigin {
            common += ["Access-Control-Allow-Origin: \(allowedOrigin)", "Vary: Origin"]
        }

        let total = resolved.fileSize
        let status: Int
        let offset: Int64
        let length: Int64
        switch ByteRange.resolve(header: headers["range"], fileSize: total) {
        case .full:
            (status, offset, length) = (200, 0, total)
        case let .partial(start, count):
            (status, offset, length) = (206, start, count)
            common.append("Content-Range: bytes \(start)-\(start + count - 1)/\(total)")
        case .unsatisfiable:
            return Self.status(416, "Range Not Satisfiable", extra: common + ["Content-Range: bytes */\(total)"])
        }

        let reason = status == 206 ? "Partial Content" : "OK"
        let headLines = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(resolved.mimeType)",
            "Content-Length: \(length)"
        ] + common + ["Connection: close"]
        let body = method == "GET" && length > 0 ? (resolved.fileURL, offset, length) : nil
        return Response(head: headLines.joined(separator: "\r\n") + "\r\n\r\n", body: body)
    }

    private static func status(_ code: Int, _ reason: String, extra: [String] = []) -> Response {
        let lines = ["HTTP/1.1 \(code) \(reason)", "Content-Length: 0"] + extra + ["Connection: close"]
        return Response(head: lines.joined(separator: "\r\n") + "\r\n\r\n", body: nil)
    }
}
