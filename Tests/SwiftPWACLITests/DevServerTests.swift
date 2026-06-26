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

        @Test("a fixed port gives a stable origin; reusing a live port throws")
        func fixedPortStableOrigin() throws {
            let web = try tmpWeb()
            defer { try? FileManager.default.removeItem(at: web) }

            // Start on an OS-assigned port to discover a currently-free one…
            let probe = DevServer(root: web, entry: "index.html", port: 0)
            let probeURL = try probe.start()
            let port = UInt16(probeURL.port ?? 0)
            #expect(port != 0)
            probe.stop()

            // …then bind that exact port: the origin is now stable/predictable.
            let server = DevServer(root: web, entry: "index.html", port: port)
            let url = try server.start()
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
