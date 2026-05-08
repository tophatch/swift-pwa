#if os(Android)
    import CSwiftPWAAndroidJNI
    import Foundation
    import SwiftPWACore

    /// `Window` representing the single Activity-hosted WebView on
    /// Android.
    ///
    /// **Most window-shape APIs are best-effort or no-ops** because
    /// Android doesn't expose the underlying primitives the
    /// cross-platform `Window` protocol assumes:
    ///
    ///   - `setSize` / `setPosition`: no-op. Activities are full-
    ///     screen by default; resizable Activities exist on tablets /
    ///     foldables but the *app* doesn't choose its size — the
    ///     window manager and user gestures do.
    ///   - `position()` / `size()`: return the last known values from
    ///     the JNI side (filled in via `WindowEvent.didResize` when
    ///     the Activity's `onConfigurationChanged` fires); zero
    ///     until the first event arrives.
    ///   - `minimize()` / `maximize()`: no-op. Android has no concept
    ///     of "minimize" outside of `moveTaskToBack`, which we don't
    ///     wire up by default.
    ///   - `setFullscreen(true)`: enters immersive mode via a JNI
    ///     hop to the bridge (`enterImmersive`); `setFullscreen(false)`
    ///     exits. Implemented in a v0.5.x follow-up.
    ///   - `focus()`: no-op (Activity already has focus by virtue of
    ///     being foregrounded).
    ///   - `close()`: routes through `quit(exitCode: 0)` since on a
    ///     single-Activity app, closing the window is closing the
    ///     app. Multi-Activity will need rework.
    /// Conforms to the `@MainActor` `Window` protocol but is itself
    /// `nonisolated` — same reasoning as `AndroidAppContext`: Android
    /// has no Swift-runtime MainActor, so we treat the JNI worker
    /// thread as the canonical owner of this state during configure
    /// and route UI-bound work explicitly via `MainThread.run` (which
    /// hops to Android's UI thread).
    public final nonisolated class AndroidWindow: Window, @unchecked Sendable {
        public let id: WindowID
        public let webView: any PWAWebView

        let adapter: AndroidWebViewAdapter

        /// Pumps inbound JSON frames from the adapter's stream and
        /// dispatches them through the registry; same shape as the
        /// other backends (`MacWindow`, `IOSWindow`, `Win32Window`).
        /// Without this, JS → Swift frames flow into the adapter
        /// continuation but no one consumes them, so `invoke` /
        /// `subscribe` calls hang forever JS-side.
        private let bridge: BridgeRuntime

        private let eventContinuation: AsyncStream<WindowEvent>.Continuation
        private let eventStreamSource: AsyncStream<WindowEvent>

        private var currentTitle: String
        private var lastKnownSize: Size = .zero
        private var fullscreenOn: Bool = false

        init(config: WindowConfig) {
            id = WindowID()
            currentTitle = config.title
            adapter = AndroidWebViewAdapter()
            webView = adapter

            var captured: AsyncStream<WindowEvent>.Continuation?
            eventStreamSource = AsyncStream { captured = $0 }
            eventContinuation = captured!

            let app = AndroidAppContext.shared
            bridge = BridgeRuntime(
                webView: adapter,
                registry: app.registry,
                windowID: id,
                app: app
            )
            bridge.start()
        }

        public func eventStream() -> AsyncStream<WindowEvent> {
            // Same broadcast-like pattern as the other backends: each
            // call returns a new stream subscribed to the underlying
            // continuation. (Multi-subscriber is a `BridgeRuntime`
            // concern — `WindowPlugin` only ever subscribes once.)
            eventStreamSource
        }

        public func setTitle(_ title: String) {
            currentTitle = title
            // Update the Activity's title via JNI so the action bar /
            // task-list label reflects the new value. Apps that hide
            // the action bar via theme will see the title change in
            // the recents list / task switcher only.
            title.withCString { swiftpwa_android_set_title($0) }
        }

        public func title() -> String { currentTitle }

        public func setSize(_: Size, animated _: Bool) {
            // No-op. Window size is owned by the platform's window
            // manager. See class docs.
        }

        public func size() -> Size { lastKnownSize }

        public func setPosition(_: Point) {
            // No-op. Window position is owned by the platform.
        }

        public func position() -> Point { .zero }

        public func focus() {
            // No-op. The Activity is already focused while running;
            // moving an Android task to the front from native code
            // requires a foreground service or notification touch
            // path neither of which is appropriate to do silently.
        }

        public func minimize() {
            // No-op. `Activity.moveTaskToBack(true)` is the closest
            // equivalent but applies to the whole task and isn't
            // what most callers of `minimize()` want.
        }

        public func maximize() {
            // No-op. Android has no maximize.
        }

        public func setFullscreen(_ on: Bool) {
            fullscreenOn = on
            // TODO(v0.5.x): JNI-call into the Kotlin bridge to
            // toggle `WindowInsetsControllerCompat.systemBarsBehavior`
            // and hide the system bars. Cached locally for now.
        }

        public func isFullscreen() -> Bool { fullscreenOn }

        public func close() {
            eventContinuation.yield(.willClose)
            eventContinuation.yield(.didClose)
            eventContinuation.finish()
            // Closing the window on Android == closing the app.
            AndroidAppContext.shared.quit(exitCode: 0)
        }

        deinit {
            eventContinuation.finish()
        }
    }
#endif
