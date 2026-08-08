import Foundation
import SwiftPWACore

#if canImport(Darwin) || canImport(Glibc) || canImport(WinSDK)

    /// A tiny static file server with live reload, for `swift-pwa dev`.
    ///
    /// Serves the project's `web/` directory over `http://127.0.0.1:<port>`,
    /// injects a one-line SSE client into every HTML response, and watches
    /// the directory tree; when a file changes it pushes a `reload` event
    /// and the page refreshes itself. No JS framework / external dev server
    /// required — point `swift-pwa dev` at a plain `web/` folder and edits
    /// show up live.
    ///
    /// The socket layer goes through `LoopbackSocket` (BSD sockets on Darwin/Glibc,
    /// Winsock on Windows) so this file carries no platform `#if`; the file
    /// watcher is plain Foundation and already portable. `@unchecked Sendable`
    /// + an `NSLock` guard the shared client list across the accept /
    /// per-connection / watcher threads — same pattern as `CommandRegistry`.
    final class DevServer: @unchecked Sendable {
        private let root: URL
        private let entry: String
        private let requestedPort: UInt16
        private let lock = NSLock()
        private var clientFds: [SocketHandle] = []
        private var listenFd: SocketHandle = LoopbackSocket.invalid
        private var running = true

        /// `port` is the loopback port to bind. A fixed, non-zero port gives
        /// the dev app a **stable origin** (`http://127.0.0.1:<port>`) across
        /// launches, so per-origin storage (OPFS, localStorage, IndexedDB)
        /// persists between runs — `0` keeps the old OS-assigned behavior
        /// (fresh origin, ephemeral storage, every launch).
        init(root: URL, entry: String, port: UInt16 = 0) {
            self.root = root
            self.entry = entry
            requestedPort = port
        }

        /// Bind the loopback port, start the accept + watch threads, and
        /// return the URL the app should load.
        func start() throws -> URL {
            LoopbackSocket.startup() // Winsock init (no-op on POSIX)
            let fd = LoopbackSocket.makeStreamSocket()
            guard LoopbackSocket.isValid(fd) else { throw DevServerError.socket("socket() failed") }
            LoopbackSocket.setReuseAddr(fd)

            guard LoopbackSocket.bindLoopback(fd, port: requestedPort) else {
                LoopbackSocket.closeSocket(fd)
                if requestedPort != 0 {
                    throw DevServerError.socket(
                        "port \(requestedPort) is already in use — pass `--port <n>` to pick another, "
                            + "or `--port 0` for an OS-assigned one (storage won't persist across launches)"
                    )
                }
                throw DevServerError.socket("bind() failed")
            }
            guard LoopbackSocket.startListening(fd, backlog: 16) else {
                LoopbackSocket.closeSocket(fd)
                throw DevServerError.socket("listen() failed")
            }

            let port = LoopbackSocket.boundPort(fd)
            listenFd = fd
            Thread.detachNewThread { [self] in acceptLoop() }
            Thread.detachNewThread { [self] in watchLoop() }

            guard let url = URL(string: "http://127.0.0.1:\(port)") else {
                throw DevServerError.socket("bad URL")
            }
            return url
        }

        func stop() {
            lock.lock()
            running = false
            let fds = clientFds + (LoopbackSocket.isValid(listenFd) ? [listenFd] : [])
            clientFds = []
            listenFd = LoopbackSocket.invalid
            lock.unlock()
            for fd in fds { LoopbackSocket.closeSocket(fd) }
        }

        // MARK: - Accept + dispatch

        private func acceptLoop() {
            while true {
                lock.lock(); let fd = listenFd; let go = running; lock.unlock()
                guard go, LoopbackSocket.isValid(fd) else { return }
                // Poll with a timeout rather than blocking in `accept()`
                // indefinitely: on Linux, `stop()` closing `listenFd` from
                // another thread does NOT wake a thread already blocked in
                // `accept()` (it does on Darwin), so a plain blocking accept
                // leaves this thread — and thus the whole process — alive after
                // `stop()`. That's what hung `swift test` on exit in CI. The
                // 300 ms timeout means we re-check `running` promptly and exit.
                let pr = LoopbackSocket.pollReadable(fd, timeoutMs: 300)
                if pr <= 0 { continue } // timeout / error → re-check `running`
                let client = LoopbackSocket.acceptOne(fd)
                if !LoopbackSocket.isValid(client) { continue }
                Thread.detachNewThread { [self] in handle(client) }
            }
        }

        private func handle(_ fd: SocketHandle) {
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = LoopbackSocket.recvInto(fd, &buf)
            guard n > 0 else { LoopbackSocket.closeSocket(fd); return }
            let request = String(decoding: buf[0 ..< n], as: UTF8.self)
            // First line: "GET /path HTTP/1.1"
            guard let line = request.split(separator: "\r\n", maxSplits: 1).first
            else { LoopbackSocket.closeSocket(fd); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { LoopbackSocket.closeSocket(fd); return }
            let rawPath = String(parts[1])
            let path = String(rawPath.split(separator: "?").first ?? "")

            if path == Self.livereloadPath {
                startSSE(fd: fd)
                return // keep the socket open; the watcher writes to it
            }
            serveFile(path: path, fd: fd)
            LoopbackSocket.closeSocket(fd)
        }

        // MARK: - Static files

        private func serveFile(path: String, fd: SocketHandle) {
            let rel = (path == "/" || path.isEmpty) ? entry : String(path.dropFirst())
            // Block path-traversal: the resolved file must stay under root.
            let fileURL = root.appendingPathComponent(rel).standardizedFileURL
            guard fileURL.path.hasPrefix(root.standardizedFileURL.path),
                  let data = try? Data(contentsOf: fileURL)
            else {
                writeAll(fd, Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            let mime = Self.mimeType(for: fileURL.pathExtension.lowercased())
            var body = [UInt8](data)
            if mime == "text/html" {
                body = injectLiveReload(into: body)
            }
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(mime)\r\n"
            header += "Content-Length: \(body.count)\r\n"
            header += "Cache-Control: no-store\r\n"
            header += "Connection: close\r\n\r\n"
            writeAll(fd, Array(header.utf8))
            writeAll(fd, body)
        }

        private func injectLiveReload(into html: [UInt8]) -> [UInt8] {
            let snippet = "<script>(function(){try{var s=new EventSource(\"\(Self.livereloadPath)\");" +
                "s.addEventListener(\"reload\",function(){location.reload()});}catch(e){}})();</script>"
            let marker = "</body>"
            if let text = String(bytes: html, encoding: .utf8), let r = text.range(of: marker, options: .backwards) {
                return Array(text.replacingCharacters(in: r, with: snippet + marker).utf8)
            }
            return html + Array(snippet.utf8) // no </body> — append
        }

        // MARK: - SSE live reload

        private func startSSE(fd: SocketHandle) {
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" +
                "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\nretry: 1000\n\n"
            writeAll(fd, Array(header.utf8))
            lock.lock(); clientFds.append(fd); lock.unlock()
        }

        private func broadcastReload() {
            lock.lock(); let fds = clientFds; lock.unlock()
            let event = Array("event: reload\ndata: 1\n\n".utf8)
            var dead: [SocketHandle] = []
            for fd in fds where !writeAll(fd, event) { dead.append(fd) }
            if !dead.isEmpty {
                lock.lock(); clientFds.removeAll { dead.contains($0) }; lock.unlock()
                for fd in dead { LoopbackSocket.closeSocket(fd) }
            }
        }

        // MARK: - File watching (cross-platform poll)

        private func watchLoop() {
            var last = signature()
            while true {
                Thread.sleep(forTimeInterval: 0.3)
                lock.lock(); let go = running; lock.unlock()
                guard go else { return }
                let now = signature()
                if now != last {
                    last = now
                    broadcastReload()
                }
            }
        }

        /// A cheap fingerprint of the tree: each file's path + size +
        /// mtime. Any add / edit / delete changes it.
        private func signature() -> String {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return "" }
            var acc = ""
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: Set(keys))
                let m = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let s = v?.fileSize ?? 0
                acc += "\(url.lastPathComponent):\(m):\(s);"
            }
            return acc
        }

        // MARK: - Helpers

        @discardableResult
        private func writeAll(_ fd: SocketHandle, _ bytes: [UInt8]) -> Bool {
            LoopbackSocket.sendAll(fd, bytes, offset: 0, count: bytes.count)
        }

        private static let livereloadPath = "/__swift_pwa_livereload__"

        private static func mimeType(for ext: String) -> String {
            switch ext {
            case "html", "htm": "text/html"
            case "js", "mjs": "text/javascript"
            case "css": "text/css"
            case "json": "application/json"
            case "wasm": "application/wasm"
            case "svg": "image/svg+xml"
            case "png": "image/png"
            case "jpg", "jpeg": "image/jpeg"
            case "gif": "image/gif"
            case "webp": "image/webp"
            case "ico": "image/x-icon"
            case "woff": "font/woff"
            case "woff2": "font/woff2"
            case "ttf": "font/ttf"
            case "map": "application/json"
            default: "application/octet-stream"
            }
        }
    }

    enum DevServerError: Error, CustomStringConvertible {
        case socket(String)
        var description: String {
            switch self { case let .socket(m): "dev server: \(m)" }
        }
    }

#endif
