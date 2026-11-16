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

#if canImport(WebKit) && (os(macOS) || os(iOS))
    /// How a served file is handed to WebKit (#346). WebKit decodes an image
    /// as its bytes arrive and paints what it has decoded, so a large PNG
    /// delivered in parts is drawn with only its top rows for a moment — and
    /// on macOS that partial frame was seen to stay. A whole file under the
    /// limit goes over in one piece; a bigger one, or a range, still streams.
    @Suite("pwa:// scheme handler — how a file is delivered")
    @MainActor
    struct WKSchemeDeliveryTests {
        @Test("a whole file under the limit reaches WebKit in one didReceive")
        func smallFileInOnePiece() async throws {
            let size = 1_400_000 // a large PNG: six 256 KB chunks
            let task = try await serve(size: size)
            #expect(task.dataCalls.count == 1)
            #expect(task.status == 200)
            #expect(task.body == bytes(size))
        }

        @Test("a file over the limit still streams in chunks")
        func largeFileStreams() async throws {
            let size = Int(WKSchemeHandler.wholeDeliveryLimit) + 1
            let task = try await serve(size: size)
            #expect(task.dataCalls.count > 1)
            #expect(task.dataCalls.allSatisfy { $0 <= 256 * 1024 })
            #expect(task.body == bytes(size))
        }

        @Test("a range request streams, whatever the file's size")
        func rangeStreams() async throws {
            let size = 1_400_000
            let task = try await serve(size: size, range: "bytes=0-")
            #expect(task.status == 206)
            #expect(task.dataCalls.count > 1)
            #expect(task.body == bytes(size))
        }

        private func bytes(_ count: Int) -> Data {
            Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        }

        private func serve(size: Int, range: String? = nil) async throws -> RecordingTask {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-delivery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try bytes(size).write(to: root.appendingPathComponent("file.bin"))
            let provider = AssetProvider()
            provider.setBundleRoot(root)
            let handler = WKSchemeHandler(provider: provider)
            var request = URLRequest(url: URL(string: "pwa://localhost/file.bin")!)
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            let task = RecordingTask(request: request)
            handler.webView(WKWebView(), start: task)
            let deadline = ContinuousClock.now + .seconds(20)
            while !task.finished, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(task.finished, "the handler never finished the task")
            return task
        }
    }

    /// Not main-actor isolated: the handler only ever messages it on the main
    /// thread, but a WebKit protocol conformance can't say so on every
    /// toolchain CI runs, so the lock makes it safe from anywhere.
    private final class RecordingTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
        let request: URLRequest
        private let lock = NSLock()
        private var _status: Int?
        private var _dataCalls: [Int] = []
        private var _body = Data()
        private var _finished = false

        var status: Int? {
            lock.withLock { _status }
        }
        var dataCalls: [Int] {
            lock.withLock { _dataCalls }
        }
        var body: Data {
            lock.withLock { _body }
        }
        var finished: Bool {
            lock.withLock { _finished }
        }

        init(request: URLRequest) {
            self.request = request
        }

        func didReceive(_ response: URLResponse) {
            lock.withLock { _status = (response as? HTTPURLResponse)?.statusCode }
        }

        func didReceive(_ data: Data) {
            lock.withLock {
                _dataCalls.append(data.count)
                _body.append(data)
            }
        }

        func didFinish() {
            lock.withLock { _finished = true }
        }

        func didFailWithError(_: any Error) {
            lock.withLock { _finished = true }
        }
    }
#endif
