// Where `bridge.js` is injected, on a real WebKitGTK view, under Xvfb.
//
// Gated on SWIFT_PWA_LINUX_GUI=1 (needs a display) like the other GTK
// integration suites; CI's Linux job doesn't build this backend at all.
//
// This is the one backend where the injection scope is the *entire* defence.
// Both GTK ports genuinely cannot report which frame sent a script message —
// `script-message-received` carries only the value, and `WebKitFrame` is
// guarded to the web-process extension API — so a check above the adapter
// could never refuse an embedded frame's invoke. What stops it is that the
// frame never gets a bridge to call with, which only WebKit can enforce and
// only a real view can prove.
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
        "GTK bridge injection scope",
        .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_LINUX_GUI"] == "1"),
        .serialized
    )
    @MainActor
    struct GTKBridgeInjectionScopeTests {
        @Test("the top frame gets bridge.js and an embedded frame does not")
        func bridgeIsTopFrameOnly() throws {
            let port = Int.random(in: 43000 ... 43999)
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swift-pwa-injection-scope-\(port)")
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // Same-origin child, which is the *harder* case: if the bridge
            // reached any embedded frame it would reach this one.
            try """
            <!doctype html><title>app</title>
            <iframe id="f" src="/child.html"></iframe>
            """.write(to: dir.appendingPathComponent("a.html"), atomically: true, encoding: .utf8)
            try """
            <!doctype html><title>child</title>
            <script>parent.postMessage('child-loaded', '*')</script>
            """.write(to: dir.appendingPathComponent("child.html"), atomically: true, encoding: .utf8)

            let server = serve(dir: dir, port: port)
            Thread.sleep(forTimeInterval: 1.5)

            initGTKForTesting()
            // `MainThread.run`'s default hook posts to libdispatch's main
            // queue, which nothing drains in a test — without the GTK hook
            // every `evaluateJavaScript` below times out, control included.
            installMainThreadHook()
            let win = try GTKWindow(
                config: WindowConfig(
                    title: "injection-scope",
                    size: Size(width: 640, height: 480),
                    visibleOnLaunch: true,
                    content: .remote(#require(URL(string: "http://127.0.0.1:\(port)/a.html")))
                ),
                app: GTKAppContext.shared
            )
            pumpMainContextForTesting(seconds: 4)
            defer {
                win.close()
                server.terminate()
                MainThread.resetHook()
                try? FileManager.default.removeItem(at: dir)
            }

            // Control that must succeed: the app's own page has the bridge. A
            // broken injection would otherwise make the real assertion pass
            // for the wrong reason.
            #expect(
                json(evaluate(win, "window.__SWIFT_PWA__ ? 'yes' : 'no'")) == "yes",
                "the top frame never got bridge.js — the assertion below proves nothing"
            )

            // Second control: the frame really loaded, so "no bridge" isn't
            // "no frame".
            #expect(
                json(evaluate(win, "document.getElementById('f').contentDocument.title")) == "child",
                "the embedded frame never loaded"
            )

            #expect(
                json(evaluate(win, "document.getElementById('f').contentWindow.__SWIFT_PWA__ ? 'yes' : 'no'")) == "no",
                "bridge.js reached an embedded frame: it must be injected into the top frame only"
            )

            // The supported route from the app's own content, which a
            // cross-origin frame cannot take.
            #expect(
                json(evaluate(win, "document.getElementById('f').contentWindow.parent.__SWIFT_PWA__ ? 'yes' : 'no'")) ==
                    "yes",
                "a same-origin frame could not reach the bridge through its parent"
            )
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

        /// The page's answer, or nil if it never came.
        private func evaluate(_ win: GTKWindow, _ js: String, seconds: Double = 6) -> String?? {
            final class Box: @unchecked Sendable {
                var value: String??
                var done = false
            }
            let box = Box()
            let webView = win.webView
            // Detached rather than `Task { @MainActor }`: the main actor is
            // backed by libdispatch's main queue, so a main-actor task would
            // never start.
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
