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
    }
#endif
