#if os(macOS)
    import AppKit
    import Foundation
    @testable import SwiftPWACore
    @testable import SwiftPWAWebKit
    import Testing
    import WebKit

    /// A backgrounded driven run rests on one piece of private API and one
    /// AppKit override. Both are the kind of thing that fails *silently* — a
    /// missing selector would leave a suite driving a window that renders
    /// nothing, and a constrained frame would drag it back onto the user's
    /// screen — so both are pinned here rather than discovered by an adopter.
    @Suite("driver background mode")
    @MainActor
    struct DriverBackgroundTests {
        /// The measurement this whole mode depends on: with occlusion detection
        /// on, a window that isn't on screen serves **0** `requestAnimationFrame`
        /// callbacks. If this selector ever goes away, the fallback is a visible
        /// run — but we should hear about it from a test, not from a suite that
        /// started timing out.
        @Test("WebKit still has the occlusion-detection switch")
        func occlusionSelectorExists() {
            let webView = WKWebView(frame: .zero)
            #expect(
                webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")),
                """
                -[WKWebView _setWindowOcclusionDetectionEnabled:] has gone. A backgrounded run now \
                falls back to a visible window; `DriverBackground` needs another way to keep an \
                off-screen page rendering.
                """
            )
        }

        /// AppKit pulls a titled window back onto a display, which is exactly
        /// right for a window a person owns — and exactly what parking one has
        /// to defeat.
        ///
        /// Asks the window the same question AppKit asks it, rather than
        /// ordering it on screen and reading the frame back.
        ///
        /// That's deliberate. The constraint really lands at **order-front**
        /// (setting the origin alone is never constrained, on either path), so
        /// the tempting test is to show both windows and compare — but showing
        /// a window needs a window server, and on a CI runner without one that
        /// took down the whole Apple test process, every unrelated suite in it
        /// included. `constrainFrameRect(_:to:)` is the override itself and is
        /// public, so this tests the seam without needing a screen to put a
        /// window on. That the parked frame survives a real order-front is
        /// covered where it can be: by driving a real app.
        @Test("the constraint is lifted for a parked window and kept for every other")
        func offscreenPlacementIsScoped() {
            let far = NSRect(
                x: DriverBackground.parkedOrigin.x,
                y: DriverBackground.parkedOrigin.y,
                width: 800,
                height: 600
            )
            func window(allowingOffscreen: Bool) -> DriverWindow {
                let window = DriverWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                // ARC owns these; AppKit's default would release them a second
                // time on close, and a window is never closed here anyway.
                window.isReleasedWhenClosed = false
                window.allowsOffscreenPlacement = allowingOffscreen
                return window
            }

            #expect(window(allowingOffscreen: true).constrainFrameRect(far, to: NSScreen.main) == far)
            // AppKit only has somewhere to pull the window back *to* when a
            // screen exists; with none (a headless runner) it answers the rect
            // it was given, which would make this assertion meaningless rather
            // than failing honestly.
            if let screen = NSScreen.main {
                #expect(
                    window(allowingOffscreen: false).constrainFrameRect(far, to: screen) != far,
                    "AppKit should have constrained an ordinary driver window back to the screen"
                )
            }
        }

        /// Requested and *honoured* are different questions — a backend that
        /// hasn't implemented backgrounding ignores the request in silence, and
        /// `capabilities.background` is what tells a harness which happened.
        @Test("the mode is off unless the environment asks for it")
        func offByDefault() {
            // The test process has no SWIFT_PWA_DRIVE_BACKGROUND set, which is
            // the normal case for every app that isn't being driven.
            #expect(ProcessInfo.processInfo.environment[DriverBackground.environmentVariable] == nil)
            #expect(!DriverBackground.isRequested)
            #expect(!DriverBackground.isActive)
        }
    }
#endif
