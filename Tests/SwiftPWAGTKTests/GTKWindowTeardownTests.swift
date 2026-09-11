// Closing a GTK window while the adapter still has work queued for the GTK
// main thread.
//
// Gated on SWIFT_PWA_LINUX_GUI=1 (needs a display — run under Xvfb on a GTK
// box) because it constructs a real `GTKWindow`, which spins up a WebKitGTK
// view. CI's Linux job doesn't build this backend at all.
//
// `GTKWindow.init` defers the first `load` onto the GTK main thread, so a test
// that closed the window before that ran used to hand
// `webkit_web_view_load_uri` a destroyed view and write the resolved origin
// into a freed `NavigationBox`, taking down the whole test process and
// `GTKFullscreenStateTests` with it (#187). The pump is what forces the queued
// job to run with the widget already gone; the assertion is that we are still
// alive to make it.
#if os(Linux)
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAGTK
    import Testing

    @Suite(
        "GTK window teardown",
        .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_LINUX_GUI"] == "1"),
        .serialized
    )
    @MainActor
    struct GTKWindowTeardownTests {
        private func makeWindow() throws -> GTKWindow {
            try GTKWindow(
                config: WindowConfig(
                    title: "teardown-test",
                    size: Size(width: 640, height: 480),
                    // Keep it lightweight — we never show it.
                    visibleOnLaunch: false,
                    content: .remote(URL(string: "about:blank")!)
                ),
                app: .shared
            )
        }

        @Test("a close before the deferred load runs leaves the queued work inert")
        func closeBeforeLoadRuns() throws {
            try withGTKMainThreadForTesting {
                let win = try makeWindow()
                // No pump in between, so the `load` scheduled by `init` is
                // still sitting in the GMainContext when the widget goes.
                win.close()
                #expect(win.adapter.lifetime.isAlive == false)

                // Now let it run. Before the fix this dereferenced the
                // destroyed view and crashed the process.
                pumpMainContextForTesting(seconds: 0.5)
            }
        }

        @Test("a window that has loaded still closes cleanly")
        func closeAfterLoadRuns() throws {
            try withGTKMainThreadForTesting {
                let win = try makeWindow()
                pumpMainContextForTesting(seconds: 0.5)
                #expect(win.adapter.lifetime.isAlive)

                win.close()
                pumpMainContextForTesting(seconds: 0.2)
                #expect(win.adapter.lifetime.isAlive == false)
            }
        }

        /// `evaluateJavaScript` resumes its continuation from the same deferred
        /// hop, so a closed window has to answer rather than strand the caller.
        @Test("evaluateJavaScript on a closed window answers nil instead of hanging")
        func evaluateAfterCloseAnswers() throws {
            try withGTKMainThreadForTesting {
                let win = try makeWindow()
                pumpMainContextForTesting(seconds: 0.5)
                win.close()

                final class Box: @unchecked Sendable {
                    var value: String??
                    var done = false
                }
                let box = Box()
                let adapter = win.adapter
                // Detached rather than `Task { @MainActor }`: the main actor is
                // backed by libdispatch's main queue, which nothing drains here.
                Task.detached {
                    box.value = try? await adapter.evaluateJavaScript("1 + 1")
                    box.done = true
                }
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline, !box.done {
                    pumpMainContextForTesting(seconds: 0.05)
                }
                #expect(box.done)
                #expect(box.value == .some(nil))
            }
        }
    }
#endif
