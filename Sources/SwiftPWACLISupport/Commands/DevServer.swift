import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)

    /// A tiny static file server with live reload, for `swift-pwa dev`.
    ///
    /// Serves the project's `web/` directory over `http://127.0.0.1:<port>`,
    /// injects a one-line SSE client into every HTML response, and watches
    /// the directory tree; when a file changes it pushes a `reload` event
    /// and the page refreshes itself. No JS framework / external dev server
    /// required — point `swift-pwa dev` at a plain `web/` folder and edits
    /// show up live.
    ///
    /// Hand-rolled POSIX sockets (no dependency, matching the project's
    /// ethos). `@unchecked Sendable` + an `NSLock` guard the shared client
    /// list across the accept / per-connection / watcher threads — same
    /// pattern as `CommandRegistry`.
    final class DevServer: @unchecked Sendable {
        private let root: URL
        private let entry: String
        private let lock = NSLock()
        private var clientFds: [Int32] = []
        private var listenFd: Int32 = -1
        private var running = true

        init(root: URL, entry: String) {
            self.root = root
            self.entry = entry
        }

        /// Bind to an OS-assigned loopback port, start the accept + watch
        /// threads, and return the URL the app should load.
        func start() throws -> URL {
            let fd = socket(AF_INET, sockStreamType, 0)
            guard fd >= 0 else { throw DevServerError.socket("socket() failed") }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0 // OS picks a free port
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindOK = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindOK == 0 else { close(fd); throw DevServerError.socket("bind() failed") }
            guard listen(fd, 16) == 0 else { close(fd); throw DevServerError.socket("listen() failed") }

            // Read back the assigned port.
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            let port = UInt16(bigEndian: bound.sin_port)

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
            let fds = clientFds + (listenFd >= 0 ? [listenFd] : [])
            clientFds = []
            listenFd = -1
            lock.unlock()
            for fd in fds { close(fd) }
        }

        // MARK: - Accept + dispatch

        private func acceptLoop() {
            while true {
                lock.lock(); let fd = listenFd; let go = running; lock.unlock()
                guard go, fd >= 0 else { return }
                // Poll with a timeout rather than blocking in `accept()`
                // indefinitely: on Linux, `stop()` closing `listenFd` from
                // another thread does NOT wake a thread already blocked in
                // `accept()` (it does on Darwin), so a plain blocking accept
                // leaves this thread — and thus the whole process — alive after
                // `stop()`. That's what hung `swift test` on exit in CI. The
                // 300 ms timeout means we re-check `running` promptly and exit.
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let pr = poll(&pfd, 1, 300)
                if pr <= 0 { continue } // timeout / EINTR → re-check `running`
                // Closed-or-errored fd (e.g. POLLNVAL after `stop()`) → loop
                // and let the `running` guard end the thread.
                if pfd.revents & Int16(POLLIN) == 0 { continue }
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                Thread.detachNewThread { [self] in handle(client) }
            }
        }

        private func handle(_ fd: Int32) {
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { close(fd); return }
            let request = String(decoding: buf[0 ..< n], as: UTF8.self)
            // First line: "GET /path HTTP/1.1"
            guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { close(fd); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { close(fd); return }
            let rawPath = String(parts[1])
            let path = String(rawPath.split(separator: "?").first ?? "")

            if path == Self.livereloadPath {
                startSSE(fd: fd)
                return // keep the socket open; the watcher writes to it
            }
            serveFile(path: path, fd: fd)
            close(fd)
        }

        // MARK: - Static files

        private func serveFile(path: String, fd: Int32) {
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

        private func startSSE(fd: Int32) {
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" +
                "Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\nretry: 1000\n\n"
            writeAll(fd, Array(header.utf8))
            lock.lock(); clientFds.append(fd); lock.unlock()
        }

        private func broadcastReload() {
            lock.lock(); let fds = clientFds; lock.unlock()
            let event = Array("event: reload\ndata: 1\n\n".utf8)
            var dead: [Int32] = []
            for fd in fds where !writeAll(fd, event) { dead.append(fd) }
            if !dead.isEmpty {
                lock.lock(); clientFds.removeAll { dead.contains($0) }; lock.unlock()
                for fd in dead { close(fd) }
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
        private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
            var offset = 0
            return bytes.withUnsafeBytes { raw -> Bool in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
                while offset < bytes.count {
                    let n = write(fd, base + offset, bytes.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
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

        /// `SOCK_STREAM` is an enum on Linux and an Int32 on Darwin; normalize.
        private var sockStreamType: Int32 {
            #if canImport(Darwin)
                SOCK_STREAM
            #else
                Int32(SOCK_STREAM.rawValue)
            #endif
        }
    }

    enum DevServerError: Error, CustomStringConvertible {
        case socket(String)
        var description: String {
            switch self { case let .socket(m): "dev server: \(m)" }
        }
    }

#endif
