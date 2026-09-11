// Apple-only: these tests drive the server through `URLSession` (incl. the
// async `bytes` SSE stream), which isn't available on swift-corelibs-
// foundation. `DevServer` itself is platform-identical POSIX socket code,
// so this macOS coverage exercises the same implementation that runs on
// Linux. (Linux execution would need a hand-rolled socket client.)
#if canImport(Darwin)

    import Foundation
    @testable import SwiftPWACLISupport
    import Testing

    @Suite("DevServer (live reload)")
    struct DevServerTests {
        private func tmpWeb() throws -> URL {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-dev-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "<!doctype html><html><body><h1>hi</h1></body></html>"
                .write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            return dir
        }

        /// Start a server on a port this test *chooses*, and retry the choice —
        /// never an assertion — if something already holds it.
        ///
        /// The number comes from below the ephemeral range (macOS hands out
        /// 49152+, `net.inet.ip.portrange.first`) so the kernel will not assign
        /// it to an outbound connection made by the rest of the suite, which
        /// runs concurrently. Randomized per attempt so a lingering server from
        /// an earlier run doesn't wedge every attempt on one number.
        private func startOnAChosenPort(web: URL) throws -> (server: DevServer, url: URL, port: UInt16) {
            var lastError: (any Error)?
            for _ in 0 ..< 20 {
                let port = UInt16.random(in: 20000 ... 29999)
                let server = DevServer(root: web, entry: "index.html", port: port)
                do {
                    let url = try server.start()
                    return (server, url, port)
                } catch {
                    // Occupied by something outside this process; try another.
                    lastError = error
                }
            }
            throw lastError ?? DevServerError.socket("no free port found in 20 attempts")
        }

        @Test("a fixed port gives a stable origin; reusing a live port throws")
        func fixedPortStableOrigin() throws {
            let web = try tmpWeb()
            defer { try? FileManager.default.removeItem(at: web) }

            // This used to bind port 0 to discover a free port, stop that
            // server and re-bind the same number — a race no test can win,
            // because the port it just released is in the range the OS hands
            // out to any outbound connection, and it lost on CI (#161).
            // Binding a chosen port directly removes the window rather than
            // narrowing it: the attempt *is* the probe. It also makes the
            // assertion stronger — the port is now the test's number to honour
            // rather than one the OS just supplied.
            let (server, url, port) = try startOnAChosenPort(web: web)
            defer { server.stop() }
            #expect(url.absoluteString == "http://127.0.0.1:\(port)")

            // A second server on the same live port fails loudly rather than
            // silently picking a different origin (which would lose storage).
            let collide = DevServer(root: web, entry: "index.html", port: port)
            #expect(throws: (any Error).self) { try collide.start() }
        }

        @Test("serves index.html with an injected live-reload client, 404s the rest")
        func servesAndInjects() async throws {
            let web = try tmpWeb()
            defer { try? FileManager.default.removeItem(at: web) }
            let server = DevServer(root: web, entry: "index.html")
            let base = try server.start()
            defer { server.stop() }

            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("/"))
            let html = String(decoding: data, as: UTF8.self)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(html.contains("<h1>hi</h1>"))
            #expect(html.contains("EventSource")) // the injected live-reload client

            let (_, missing) = try await URLSession.shared.data(from: base.appendingPathComponent("/nope.js"))
            #expect((missing as? HTTPURLResponse)?.statusCode == 404)
        }

        @Test("pushes a reload event when a file changes")
        func reloadsOnChange() async throws {
            let web = try tmpWeb()
            defer { try? FileManager.default.removeItem(at: web) }
            let server = DevServer(root: web, entry: "index.html")
            let base = try server.start()
            defer { server.stop() }

            let sse = base.appendingPathComponent("/__swift_pwa_livereload__")
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    let (bytes, _) = try await URLSession.shared.bytes(from: sse)
                    for try await line in bytes.lines where line.contains("reload") {
                        return true
                    }
                    return false
                }
                group.addTask {
                    // Give the SSE connection a moment, then change a file.
                    try await Task.sleep(nanoseconds: 600_000_000)
                    try "<!doctype html><html><body><h1>changed</h1></body></html>"
                        .write(to: web.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
                    return false
                }
                group.addTask {
                    // Safety timeout so a regression fails fast instead of hanging.
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    return false
                }
                // The reader task returning true is the pass condition.
                var sawReload = false
                for try await result in group where result {
                    sawReload = true
                    group.cancelAll()
                    break
                }
                #expect(sawReload)
            }
        }
    }

#endif
