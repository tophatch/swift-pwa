// The `pwa://` scheme handler through a real WebKitGTK view, with a served
// file whose bytes aren't there yet (#338).
//
// Gated on SWIFT_PWA_LINUX_GUI=1 (needs a display — run under Xvfb on a GTK
// box) because it constructs a real `GTKWindow`. CI's Linux job doesn't build
// this backend at all.
//
// The slow file is a FIFO: opening one for reading blocks until a writer opens
// it, which is what opening a file on a network or FUSE mount does — wait on
// I/O for as long as the bytes take. Here the test decides when they arrive.
// The handler runs while the test pumps the GMainContext, so a handler that
// opens on the main thread blocks the test itself until the watchdog lets it
// go — which is what `byTest()` reports.
#if os(Linux)
    import Foundation
    import Glibc // mkfifo(3), open(2)
    import SwiftPWACore
    @testable import SwiftPWAGTK
    import Testing

    @Suite(
        "GTK pwa:// serving — a file that isn't on disk yet",
        .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_LINUX_GUI"] == "1"),
        .serialized
    )
    @MainActor
    struct GTKSchemeServingTests {
        @Test("a pending read holds up neither the main thread nor the next request")
        func pendingReadBlocksNothing() throws {
            let site = try Site()
            defer { site.remove() }
            try withGTKMainThreadForTesting {
                // Released by the test once it sees the fast file, or by a
                // watchdog that keeps a handler blocking the main thread from
                // hanging the run.
                let release = site.releaseSlow(after: 15)
                let win = try site.load("""
                window.__slow = 'pending';
                fetch('slow.txt').then(r => r.text()).then(t => { window.__slow = 'done:' + t; });
                fetch('fast.txt').then(r => r.text()).then(t => { window.__fast = t; });
                """)
                defer { win.close() }

                #expect(waitForJS(win, "window.__fast") == "FAST")
                #expect(waitForJS(win, "window.__slow") == "pending")
                #expect(release.byTest(), "the watchdog had to release the slow file, so the main thread was blocked")
                #expect(waitForJS(win, "window.__slow === 'pending' ? null : window.__slow") == "done:")
            }
        }

        @Test("a request aborted while its read is pending is finished safely")
        func abortedRequestIsFinishedSafely() throws {
            let site = try Site()
            defer { site.remove() }
            try withGTKMainThreadForTesting {
                let release = site.releaseSlow(after: 15)
                let win = try site.load("""
                const abort = new AbortController();
                fetch('slow.txt', { signal: abort.signal }).catch(e => { window.__slow = e.name; });
                setTimeout(() => abort.abort(), 200);
                """)
                defer { win.close() }
                #expect(waitForJS(win, "window.__slow") == "AbortError")

                // The worker is still in `open`. Let it through, and let the
                // finish land on a request WebKit has already cancelled.
                #expect(release.byTest(), "the watchdog had to release the slow file, so the main thread was blocked")
                pumpMainContextForTesting(seconds: 0.5)
                #expect(waitForJS(win, "String(1 + 1)") == "2")
            }
        }

        @Test("a window closed while its read is pending leaves nothing to crash on")
        func windowClosedWhileReadPending() throws {
            let site = try Site()
            defer { site.remove() }
            try withGTKMainThreadForTesting {
                let release = site.releaseSlow(after: 15)
                let win = try site.load("""
                fetch('slow.txt');
                fetch('fast.txt').then(r => r.text()).then(t => { window.__fast = t; });
                """)
                #expect(waitForJS(win, "window.__fast") == "FAST")
                win.close()
                pumpMainContextForTesting(seconds: 0.2)

                #expect(release.byTest(), "the watchdog had to release the slow file, so the main thread was blocked")
                // The finish arrives for a view that is gone; the process
                // surviving this pump is the assertion.
                pumpMainContextForTesting(seconds: 1)
            }
        }

        @Test("full files, ranges and misses are still answered correctly")
        func rangesStillServed() throws {
            let site = try Site()
            defer { site.remove() }
            let body = String(repeating: "0123456789", count: 60000) // 600 KB
            try Data(body.utf8).write(to: site.root.appendingPathComponent("big.txt"))
            try withGTKMainThreadForTesting {
                let win = try site.load("""
                const range = (r) => fetch('big.txt', { headers: { Range: r } })
                    .then(res => res.text().then(t => res.status + ':' + t.length + ':' + t.slice(0, 5)));
                fetch('big.txt').then(r => r.text()).then(t => { window.__full = t.length + ':' + t.slice(-3); });
                range('bytes=10-14').then(v => { window.__bounded = v; });
                range('bytes=599995-').then(v => { window.__toEnd = v; });
                fetch('big.txt', { headers: { Range: 'bytes=700000-' } })
                    .then(r => { window.__unsatisfiable = String(r.status); });
                fetch('missing.txt').then(r => { window.__missing = 'status ' + r.status; },
                                          e => { window.__missing = e.name; });
                """)
                defer { win.close() }
                #expect(waitForJS(win, "window.__full") == "600000:789")
                #expect(waitForJS(win, "window.__bounded") == "206:5:01234")
                #expect(waitForJS(win, "window.__toEnd") == "206:5:56789")
                #expect(waitForJS(win, "window.__unsatisfiable") == "416")
                #expect(waitForJS(win, "window.__missing") == "TypeError")
            }
        }

        // MARK: - Harness

        /// A bundle directory holding `index.html`, `fast.txt` and the
        /// `slow.txt` FIFO.
        private struct Site {
            let root: URL
            var slow: URL {
                root.appendingPathComponent("slow.txt")
            }

            init() throws {
                root = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("swiftpwa-scheme-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("FAST".utf8).write(to: root.appendingPathComponent("fast.txt"))
                guard mkfifo(slow.path, 0o600) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            @MainActor
            func load(_ script: String) throws -> GTKWindow {
                try Data("<!doctype html><script>\(script)</script>".utf8)
                    .write(to: root.appendingPathComponent("index.html"))
                return try GTKWindow(
                    config: WindowConfig(
                        title: "scheme-serving",
                        size: Size(width: 640, height: 480),
                        visibleOnLaunch: true,
                        content: .bundled(directory: root, entry: "index.html", spaFallback: false)
                    ),
                    app: .shared
                )
            }

            /// Opens the FIFO for writing once a reader has it open — which
            /// is what lets the handler's `open` return — and closes it at
            /// once, so the read sees an empty file. `byTest()` releases it
            /// now; the watchdog does after `seconds` if nobody has.
            func releaseSlow(after seconds: Int) -> SlowRelease {
                SlowRelease(path: slow.path, seconds: seconds)
            }

            func remove() {
                try? FileManager.default.removeItem(at: root)
            }
        }

        private final class SlowRelease: @unchecked Sendable {
            private let path: String
            private let lock = NSLock()
            private var released = false

            init(path: String, seconds: Int) {
                self.path = path
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { [self] in _ = release() }
            }

            /// True when this call released it, false if the watchdog got
            /// there first.
            func byTest() -> Bool {
                release()
            }

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

        /// Poll `expr` until it is non-null, pumping the GMainContext between
        /// tries. Bounded both ways: each evaluation gets a few seconds, and
        /// the whole wait gets `seconds`.
        private func waitForJS(_ win: GTKWindow, _ expr: String, seconds: Double = 20) -> String? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let value = json(evaluate(win, expr)) { return value }
                pumpMainContextForTesting(seconds: 0.05)
            }
            return nil
        }

        private func evaluate(_ win: GTKWindow, _ js: String, seconds: Double = 4) -> String?? {
            final class Box: @unchecked Sendable {
                var value: String??
                var done = false
            }
            let box = Box()
            let webView = win.webView
            // Detached rather than `Task { @MainActor }`: the main actor is
            // backed by libdispatch's main queue, so a main-actor task would
            // never start. Only the inner hop needs the pump below.
            Task.detached {
                box.value = try? await webView.evaluateJavaScript(js)
                box.done = true
            }
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                pumpMainContextForTesting(seconds: 0.05)
                if box.done { return box.value }
            }
            return nil
        }

        /// `evaluateJavaScript` answers with a JSON serialization, so a string
        /// result arrives quoted; `null` and `undefined` read as nil.
        private func json(_ result: String??) -> String? {
            guard let inner = result, let text = inner, text != "null" else { return nil }
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(
                      with: data, options: [.fragmentsAllowed]
                  ) as? String
            else { return text }
            return value
        }
    }
#endif
