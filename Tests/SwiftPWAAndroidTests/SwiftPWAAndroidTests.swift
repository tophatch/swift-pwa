#if os(Android)
    @testable import SwiftPWAAndroid
    import SwiftPWACore
    import Testing

    /// Android backend tests are minimal in v0.5 because most of the
    /// surface area lives behind a JNI hop and is only meaningful on
    /// a real Android target. These tests exist to give the
    /// `SwiftPWAAndroid` target something to compile against under
    /// `swift test` once a Swift Android toolchain produces a test
    /// binary; the substantive verification is the manual cases
    /// added to `docs/manual-test-cases.md` (Android section, queued
    /// for v0.5.x).
    struct AndroidWindowTests {
        @MainActor
        @Test func windowReportsConfiguredTitle() {
            let cfg = WindowConfig(
                title: "Hello",
                size: Size(width: 360, height: 640),
                content: .bundled(directory: URL(fileURLWithPath: "/tmp/web"))
            )
            let win = AndroidWindow(config: cfg)
            #expect(win.title() == "Hello")
        }

        @MainActor
        @Test func setTitleRoundTrips() {
            let cfg = WindowConfig(
                title: "Initial",
                size: Size(width: 360, height: 640),
                content: .bundled(directory: URL(fileURLWithPath: "/tmp/web"))
            )
            let win = AndroidWindow(config: cfg)
            win.setTitle("Updated")
            #expect(win.title() == "Updated")
        }

        @MainActor
        @Test func setSizeAndPositionAreNoOps() {
            // The platform owns these on Android; we document the
            // contract by pinning it in a test.
            let cfg = WindowConfig(
                title: "x",
                size: Size(width: 100, height: 100),
                content: .bundled(directory: URL(fileURLWithPath: "/tmp/web"))
            )
            let win = AndroidWindow(config: cfg)
            win.setSize(Size(width: 200, height: 200), animated: false)
            win.setPosition(Point(x: 50, y: 50))
            #expect(win.position() == .zero)
        }

        @MainActor
        @Test func secondaryWindowSkipsCrossActivityJNI() throws {
            // A `.secondary` AndroidWindow represents an Activity
            // spawned via `swiftpwa_android_spawn_window`. The C
            // shim's bridge ref is single-slot, so cross-Activity
            // Swift→OS calls would silently target the wrong
            // Activity. `setTitle` / `setFullscreen` / `close()` on a
            // secondary window stay local-only; `title()` /
            // `isFullscreen()` still report the requested values
            // from the caller's perspective.
            let cfg = try WindowConfig(
                title: "secondary",
                size: Size(width: 100, height: 100),
                content: .remote(#require(URL(string: "https://example.com")))
            )
            let win = AndroidWindow(config: cfg, role: .secondary)
            #expect(win.role == .secondary)
            // Title cache updates, JNI hop is skipped (no crash
            // testing required — the cache visibility is the
            // observable behaviour).
            win.setTitle("renamed")
            #expect(win.title() == "renamed")
            // Fullscreen mirror flips locally.
            win.setFullscreen(true)
            #expect(win.isFullscreen() == true)
            // close() on a secondary doesn't quit the app — it just
            // emits the lifecycle events for the AndroidWindow's
            // own stream consumers.
            win.close()
        }

        @MainActor
        @Test func setFullscreenTracksState() {
            // `setFullscreen` JNI-calls into the bridge to drive
            // `WindowInsetsControllerCompat`; the call is a no-op if
            // no bridge is attached (typical for a unit test). The
            // local mirror still flips so `isFullscreen()` is honest
            // about the most-recent caller intent before the JNI
            // round-trip lands.
            let cfg = WindowConfig(
                title: "x",
                size: Size(width: 100, height: 100),
                content: .bundled(directory: URL(fileURLWithPath: "/tmp/web"))
            )
            let win = AndroidWindow(config: cfg)
            #expect(win.isFullscreen() == false)
            win.setFullscreen(true)
            #expect(win.isFullscreen() == true)
            win.setFullscreen(false)
            #expect(win.isFullscreen() == false)
        }
    }
#endif
