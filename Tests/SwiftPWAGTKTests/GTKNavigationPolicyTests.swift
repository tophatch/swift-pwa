// The navigation policy on a real WebKitGTK view, under Xvfb.
//
// Gated on SWIFT_PWA_LINUX_GUI=1 (needs a display) like the other GTK
// integration suites; CI's Linux job doesn't build this backend at all.
//
// It exists because the *interesting* part of this backend isn't the rule —
// that lives in `ExternalURLPolicy` and is unit-tested without a webview —
// but which WebKit decisions carry which information. Measured while writing
// it: a cross-origin `<iframe>`'s own load arrives at `decide-policy`
// indistinguishable from the main frame navigating away (`frame_name` is NULL
// for both), so a policy applied to every navigation decision would hand
// every embedded map or video to the browser. The iframe assertion below is
// the guard on that.
#if os(Linux)
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAGTK
    import Testing

    #if canImport(CGtk4Shim)
        import CGtk4Shim
    #elseif canImport(CGtk3Shim)
        import CGtk3Shim
    #endif

    @Suite(
        "GTK navigation policy",
        .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_LINUX_GUI"] == "1"),
        .serialized
    )
    @MainActor
    struct GTKNavigationPolicyTests {
        /// Two local origins: the app's page, and a second one standing in for
        /// "somewhere else on the web".
        private struct Fixture {
            let window: GTKWindow
            let appPort: Int
            let otherPort: Int
            let servers: [Process]
        }

        @Test("off-origin navigation leaves the app where it is, and embeds still load")
        func policedNavigation() throws {
            let fixture = try makeFixture()
            defer {
                fixture.window.close()
                for server in fixture.servers { server.terminate() }
                MainThread.resetHook()
            }
            let win = fixture.window
            let other = "http://127.0.0.1:\(fixture.otherPort)"
            let home = "http://127.0.0.1:\(fixture.appPort)/a.html"

            #expect(json(evaluate(win, "location.href")) == home)

            // Both cross-origin iframes must have loaded. They announce
            // themselves by postMessage because the page can't read into a
            // cross-origin frame — and because a server access log turned out
            // to be a much worse instrument (buffered, and a stale server from
            // an earlier run answered on a fixed port). Compared as a *set*:
            // which frame wins the race isn't part of the contract, and GTK4
            // ordered them the other way round.
            let loaded = json(evaluate(win, "JSON.stringify((window.__frames || []).sort())"))
            #expect(loaded == #"["frame?one=1","frame?two=1"]"#)

            // A user-initiated link click: caught at the navigation decision,
            // before any request is made.
            _ = evaluate(win, "document.getElementById('out').click(); 'clicked'", seconds: 2)
            pumpMainContextForTesting(seconds: 3)
            #expect(json(evaluate(win, "location.href")) == home)
            #expect(RecordedOpens.all.contains("\(other)/frame.html"))

            // A programmatic redirect is *not* user-initiated, so only the
            // response decision — the one carrying `is_main_frame_main_resource`
            // — can catch it. Cancelling there leaves the old document up.
            _ = evaluate(win, "location.href = '\(other)/frame.html?redirect=1'; 'x'", seconds: 2)
            pumpMainContextForTesting(seconds: 4)
            #expect(json(evaluate(win, "location.href")) == home)
            #expect(RecordedOpens.all.contains("\(other)/frame.html?redirect=1"))

            // Same-origin navigation is untouched.
            _ = evaluate(win, "location.href = 'http://127.0.0.1:\(fixture.appPort)/b.html'; 'x'", seconds: 2)
            pumpMainContextForTesting(seconds: 4)
            #expect(json(evaluate(win, "location.href")) == "http://127.0.0.1:\(fixture.appPort)/b.html")
        }

        // MARK: - Harness

        private func makeFixture() throws -> Fixture {
            // Ports per run: a fixed pair let a stale server from an earlier
            // run answer instead, serving *its* directory — which silently
            // invalidated every reading until it was spotted.
            let appPort = Int.random(in: 20000 ... 40000)
            let otherPort = appPort + 1
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swiftpwa-nav-\(UUID().uuidString)")
            let appDir = root.appendingPathComponent("app")
            let otherDir = root.appendingPathComponent("other")
            for dir in [appDir, otherDir] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try """
            <!doctype html><title>app</title>
            <p><a id="out" href="http://127.0.0.1:\(otherPort)/frame.html">off-origin link</a></p>
            <iframe id="f" src="http://127.0.0.1:\(otherPort)/frame.html?one=1"></iframe>
            <iframe id="named" name="embed" src="http://127.0.0.1:\(otherPort)/frame.html?two=1"></iframe>
            <script>
              window.__frames = [];
              addEventListener('message', (e) => { window.__frames.push(String(e.data)); });
            </script>
            """.write(to: appDir.appendingPathComponent("a.html"), atomically: true, encoding: .utf8)
            try "<!doctype html><title>b</title><p>second page</p>"
                .write(to: appDir.appendingPathComponent("b.html"), atomically: true, encoding: .utf8)
            try #"<!doctype html><title>frame</title><script>parent.postMessage('frame'+location.search,'*')</script>"#
                .write(to: otherDir.appendingPathComponent("frame.html"), atomically: true, encoding: .utf8)

            let servers = [serve(dir: appDir, port: appPort), serve(dir: otherDir, port: otherPort)]
            Thread.sleep(forTimeInterval: 1.5)

            setenv("SWIFT_PWA_RECORD_OPENS", "1", 1)
            RecordedOpens.reset()
            initGTKForTesting()
            // `MainThread.run`'s default hook posts to libdispatch's main
            // queue, which nothing drains in a test — so without the GTK hook
            // every `evaluateJavaScript` below times out, control included.
            // Each test restores the default when it tears the fixture down;
            // the hook is process-global and only delivers while we pump.
            installMainThreadHook()
            let window = try GTKWindow(
                config: WindowConfig(
                    title: "nav-policy",
                    size: Size(width: 640, height: 480),
                    visibleOnLaunch: true,
                    content: .remote(URL(string: "http://127.0.0.1:\(appPort)/a.html")!)
                ),
                app: GTKAppContext.shared
            )
            pumpMainContextForTesting(seconds: 4)
            return Fixture(window: window, appPort: appPort, otherPort: otherPort, servers: servers)
        }

        private func serve(dir: URL, port: Int) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", "-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
            process.currentDirectoryURL = dir
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            return process
        }

        /// The page's answer, or nil if it never came — which is what a modal
        /// dialog or a wedged load looks like from here.
        private func evaluate(_ win: GTKWindow, _ js: String, seconds: Double = 6) -> String?? {
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
        /// result arrives quoted.
        private func json(_ result: String??) -> String? {
            guard let inner = result, let text = inner else { return nil }
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(
                      with: data, options: [.fragmentsAllowed]
                  ) as? String
            else { return text }
            return value
        }
    }
#endif
