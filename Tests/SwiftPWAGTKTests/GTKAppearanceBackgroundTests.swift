// A light/dark window background following the desktop's appearance.
//
// Gated on SWIFT_PWA_LINUX_GUI=1 (needs a display — run under Xvfb on a GTK
// box) because it constructs a real `GTKWindow`, which spins up a WebKitGTK
// view. CI's Linux job doesn't build the GTK backend at all.
//
// `gtk-application-prefer-dark-theme` is the right signal to follow, measured
// rather than assumed: with it set, WebKitGTK reports
// `prefers-color-scheme: dark` to the page on both 4.1 (GTK3) and 6.0 (GTK4).
// So this test drives the same property a desktop's settings daemon would.
#if os(Linux)
    import Foundation
    import SwiftPWACore
    @testable import SwiftPWAGTK
    import Testing

    @Suite(
        "GTK appearance-aware window background",
        .enabled(if: ProcessInfo.processInfo.environment["SWIFT_PWA_LINUX_GUI"] == "1"),
        .serialized
    )
    @MainActor
    struct GTKAppearanceBackgroundTests {
        private func setPrefersDark(_ dark: Bool) {
            GTKAppearance.setPrefersDarkForTesting(dark)
        }

        private func makeWindow(_ background: WindowBackgroundColor?) throws -> GTKWindow {
            try GTKWindow(
                config: WindowConfig(
                    title: "bg-test",
                    size: Size(width: 640, height: 480),
                    // Keep it lightweight — we never show it.
                    visibleOnLaunch: false,
                    content: .remote(URL(string: "about:blank")!),
                    backgroundColor: background
                ),
                app: .shared
            )
        }

        /// 8-bit channels: WebKit stores the colour as floats, so an exact
        /// `Double` comparison would be at the mercy of the round trip.
        private func bytes(_ window: GTKWindow) -> (UInt8, UInt8, UInt8) {
            let b = window.adapter.backgroundColor().bytes
            return (b.r, b.g, b.b)
        }

        private let pair = WindowBackgroundColor.dayNight(light: "#FF4400", dark: "#0044FF")

        @Test("a pair paints the half the desktop currently asks for")
        func resolvesAtCreation() throws {
            try withGTKMainThreadForTesting {
                setPrefersDark(false)
                let light = try makeWindow(pair)
                defer { light.close() }
                #expect(bytes(light) == (0xFF, 0x44, 0x00))

                setPrefersDark(true)
                let dark = try makeWindow(pair)
                defer { dark.close() }
                #expect(bytes(dark) == (0x00, 0x44, 0xFF))
                setPrefersDark(false)
            }
        }

        @Test("a pair repaints when the desktop switches under a running window")
        func followsALiveChange() throws {
            try withGTKMainThreadForTesting {
                setPrefersDark(false)
                let win = try makeWindow(pair)
                defer { win.close() }
                #expect(bytes(win) == (0xFF, 0x44, 0x00))

                // What a settings daemon does; the `notify::` handler installed
                // by `GTKAppearance` is what has to notice.
                setPrefersDark(true)
                #expect(bytes(win) == (0x00, 0x44, 0xFF))

                setPrefersDark(false)
                #expect(bytes(win) == (0xFF, 0x44, 0x00))
            }
        }

        @Test("one colour stays put across an appearance switch")
        func singleColourIsUnaffected() throws {
            try withGTKMainThreadForTesting {
                setPrefersDark(false)
                let win = try makeWindow("#123456")
                defer { win.close() }
                #expect(bytes(win) == (0x12, 0x34, 0x56))
                setPrefersDark(true)
                #expect(bytes(win) == (0x12, 0x34, 0x56))
                setPrefersDark(false)
            }
        }
    }
#endif
