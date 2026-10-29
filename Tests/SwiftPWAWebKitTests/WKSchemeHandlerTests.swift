#if canImport(WebKit) && (os(macOS) || os(iOS))
    import Darwin
    import Foundation
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing
    import WebKit

    /// The `pwa://` scheme handler through a real `WKWebView`, with a served
    /// file whose bytes aren't there yet (#338).
    ///
    /// The slow file is a FIFO: opening one for reading blocks until a writer
    /// opens it, which is what reading an iCloud placeholder or a file on a
    /// network volume does — wait on I/O for as long as the bytes take. Here
    /// the test decides when they arrive.
    @Suite("pwa:// scheme handler — a file that isn't on disk yet")
    @MainActor
    struct WKSchemeHandlerTests {
        @Test("a pending read holds up neither the main thread nor the next request")
        func pendingReadBlocksNothing() async throws {
            let site = try Site()
            defer { site.remove() }
            // Released by the test once it sees the fast file, or by a watchdog
            // that keeps a handler that blocks the main thread from hanging the
            // run — `evaluateJavaScript` can't return while it's blocked.
            let release = site.releaseSlow(after: .seconds(15))
            let adapter = try site.load("""
            window.__slow = 'pending';
            fetch('slow.txt').then(r => r.text()).then(t => { window.__slow = 'done:' + t; });
            fetch('fast.txt').then(r => r.text()).then(t => { window.__fast = t; });
            """)

            #expect(try await waitForJS(in: adapter, "window.__fast") == "FAST")
            #expect(try await adapter.evaluateJavaScript("window.__slow").map(unquote) == "pending")
            #expect(release.byTest(), "the watchdog had to release the slow file, so the main thread was blocked")
            #expect(try await waitForJS(in: adapter, "window.__slow === 'pending' ? null : window.__slow") == "done:")
        }

        @Test("a request stopped while its read is pending is never messaged again")
        func stoppedTaskIsLeftAlone() async throws {
            let site = try Site()
            defer { site.remove() }
            let release = site.releaseSlow(after: .seconds(15))
            let adapter = try site.load("""
            const abort = new AbortController();
            fetch('slow.txt', { signal: abort.signal }).catch(e => { window.__slow = e.name; });
            setTimeout(() => abort.abort(), 200);
            """)
            #expect(try await waitForJS(in: adapter, "window.__slow") == "AbortError")

            // The worker is still in `open`. Let it through: WebKit raises an
            // Objective-C exception, which ends the test process, if the
            // handler sends a stopped task anything at all.
            #expect(release.byTest(), "the watchdog had to release the slow file, so the main thread was blocked")
            try await Task.sleep(for: .milliseconds(500))
            #expect(try await adapter.evaluateJavaScript("1 + 1") == "2")
        }

        @Test("a range is served from off the main thread with the right bytes")
        func rangeStillServed() async throws {
            let site = try Site()
            defer { site.remove() }
            let body = String(repeating: "0123456789", count: 60000) // 600 KB, three chunks
            try Data(body.utf8).write(to: site.root.appendingPathComponent("big.txt"))
            let adapter = try site.load("""
            fetch('big.txt').then(r => r.text()).then(t => { window.__full = t.length + ':' + t.slice(-3); });
            fetch('big.txt', { headers: { Range: 'bytes=10-14' } })
                .then(r => r.text().then(t => { window.__range = r.status + ':' + t; }));
            """)
            #expect(try await waitForJS(in: adapter, "window.__full") == "600000:789")
            #expect(try await waitForJS(in: adapter, "window.__range") == "206:01234")
        }

        /// A served directory holding `index.html`, `fast.txt` and the
        /// `slow.txt` FIFO.
        private struct Site {
            let root: URL
            var slow: URL {
                root.appendingPathComponent("slow.txt")
            }

            init() throws {
                root = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("swift-pwa-scheme-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("FAST".utf8).write(to: root.appendingPathComponent("fast.txt"))
                guard mkfifo(slow.path, 0o600) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            @MainActor
            func load(_ script: String) throws -> WKWebViewAdapter {
                try Data("<!doctype html><script>\(script)</script>".utf8)
                    .write(to: root.appendingPathComponent("index.html"))
                let provider = AssetProvider()
                provider.setBundleRoot(root)
                let configuration = WKWebViewConfiguration()
                WKWebViewAdapter.registerScheme("pwa", on: configuration, assetProvider: provider)
                let adapter = try WKWebViewAdapter(configuration: configuration)
                adapter.webView.load(URLRequest(url: URL(string: "pwa://localhost/index.html")!))
                return adapter
            }

            /// Opens the FIFO for writing once a reader has it open — which
            /// is what lets the handler's `open` return — and closes it at
            /// once, so the read sees an empty file. `byTest()` releases it
            /// now; the watchdog does after `deadline` if nobody has.
            func releaseSlow(after deadline: Duration) -> SlowRelease {
                SlowRelease(path: slow.path, deadline: deadline)
            }

            func remove() {
                try? FileManager.default.removeItem(at: root)
            }
        }

        private final class SlowRelease: @unchecked Sendable {
            private let path: String
            private let lock = NSLock()
            private var released = false

            init(path: String, deadline: Duration) {
                self.path = path
                let watchdog = DispatchTime.now() + .milliseconds(Int(deadline.components.seconds * 1000))
                DispatchQueue.global().asyncAfter(deadline: watchdog) { [self] in _ = release() }
            }

            /// True when this call released it, false if the watchdog got
            /// there first.
            func byTest() -> Bool { release() }

            private func release() -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard !released else { return false }
                released = true
                // Non-blocking, so a FIFO nobody is reading fails (ENXIO)
                // instead of waiting for a reader; retry while the handler's
                // worker gets to its `open`.
                for _ in 0 ..< 50 {
                    let fd = open(path, O_WRONLY | O_NONBLOCK)
                    if fd >= 0 { close(fd); return true }
                    usleep(100_000)
                }
                return true
            }
        }

        private func waitForJS(
            in adapter: WKWebViewAdapter,
            _ expr: String,
            timeout: Duration = .seconds(20)
        ) async throws -> String? {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let value = try await adapter.evaluateJavaScript(expr), value != "<null>", value != "(null)" {
                    return unquote(value)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }

        private func unquote(_ json: String) -> String {
            (try? JSONDecoder().decode(String.self, from: Data(json.utf8))) ?? json
        }
    }
#endif
