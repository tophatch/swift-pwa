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
        /// The constraint lands at **order-front**, not at `setFrameOrigin`: a
        /// parked frame reads back fine right up until the window is shown, and
        /// then snaps to the screen edge. So this orders both windows in, the
        /// same way `MacWindow` does, or it would pass while testing nothing.
        @Test("a parked window stays parked, and a normal one doesn't")
        func offscreenPlacementIsScoped() {
            let far = NSPoint(x: DriverBackground.parkedOrigin.x, y: DriverBackground.parkedOrigin.y)

            func show(allowingOffscreen: Bool) -> NSPoint {
                let window = DriverWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.allowsOffscreenPlacement = allowingOffscreen
                window.setFrameOrigin(far)
                window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
                window.orderFrontRegardless()
                defer { window.close() }
                return window.frame.origin
            }

            #expect(show(allowingOffscreen: true) == far)
            #expect(
                show(allowingOffscreen: false) != far,
                "AppKit should have constrained an ordinary driver window back to a screen"
            )
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
