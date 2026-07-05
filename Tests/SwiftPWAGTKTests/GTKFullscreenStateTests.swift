// Programmatic fullscreen state tracking on the GTK backend.
//
// Gated on SWIFT_PWA_LINUX_GUI=1 (needs a display — run under Xvfb on the
// GTK box) because it constructs a real `GTKWindow`, which spins up a
// WebKitGTK view. CI's Linux job doesn't build the GTK backend at all, so
// this only ever runs on a GTK-capable machine.
#if os(Linux)
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAGTK
    import Testing

    @Suite(
        "GTK fullscreen state",
        .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_LINUX_GUI"] == "1"),
        .serialized
    )
    @MainActor
    struct GTKFullscreenStateTests {
        private func makeConfig(fullscreen: Bool) -> WindowConfig {
            WindowConfig(
                title: "fs-test",
                size: Size(width: 640, height: 480),
                fullscreen: fullscreen,
                // Keep it lightweight — we never show it.
                visibleOnLaunch: false,
                content: .remote(URL(string: "about:blank")!)
            )
        }

        @Test("isFullscreen() mirrors setFullscreen()")
        func tracksProgrammaticToggle() throws {
            initGTKForTesting()
            let win = try GTKWindow(config: makeConfig(fullscreen: false), app: .shared)
            defer { win.close() }

            #expect(win.isFullscreen() == false)
            win.setFullscreen(true)
            #expect(win.isFullscreen() == true)
            win.setFullscreen(false)
            #expect(win.isFullscreen() == false)
        }

        @Test("a window created fullscreen reports true immediately")
        func honorsConfigFullscreen() throws {
            initGTKForTesting()
            let win = try GTKWindow(config: makeConfig(fullscreen: true), app: .shared)
            defer { win.close() }

            #expect(win.isFullscreen() == true)
        }
    }
#endif
