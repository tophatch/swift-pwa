import Foundation

/// Cross-platform webview contract. Backends wrap `WKWebView` /
/// `WebKitWebView` and provide:
///   - the channel used to receive `InboundFrame`s from JS
///   - a way to send `OutboundFrame`s to JS (typically via injected JS
///     that calls a global resolver table)
///   - script evaluation / loading primitives.
/// Cross-platform webview contract.
///
/// Methods are *not* `@MainActor` — backends are responsible for
/// hopping to their platform's UI thread internally (typically via
/// `MainThread.run`). This is what lets `BridgeRuntime` pump frames
/// from the cooperative pool without deadlocking on Linux, where
/// Swift's MainActor executor isn't pumped by `gtk_main()`.
public protocol PWAWebView: AnyObject, Sendable {
    /// Load (or reload) the configured content into this webview.
    func load(_ content: WindowContent)

    /// Run an arbitrary JavaScript snippet in the page. Returns the
    /// JSON-string representation of the result, if any.
    func evaluateJavaScript(_ js: String) async throws -> String?

    /// Push one outbound frame to the JS side. The default
    /// implementation in each backend serializes via `Envelope.encode`
    /// and dispatches `globalThis.__SWIFT_PWA__.__deliver(<json>)`.
    func deliver(_ frame: OutboundFrame) async throws

    /// Stream of frames received from JS. Each `WebView` exposes its
    /// own broadcast; `BridgeRuntime` consumes one stream per webview.
    func inboundFrames() -> AsyncStream<InboundFrame>

    /// Open the platform's web inspector / DevTools window. Called
    /// from the platform-standard accelerator (Cmd+Opt+J on Apple,
    /// Ctrl+Alt+J on Linux + Windows). No-op on backends that don't
    /// expose programmatic DevTools (currently iOS — its WKWebView
    /// is debugged via Safari's *Develop* menu on a paired Mac).
    func openDevTools()

    /// PNG bytes of this webview's **rendered contents**.
    ///
    /// Deliberately the webview's pixels rather than the screen's: the
    /// window may be occluded, in the background, or on another Space, and
    /// the capture must still be of the app and only the app. That rules
    /// out the screen-capture APIs (which additionally want a TCC grant on
    /// macOS) in favour of each backend's own renderer snapshot —
    /// `WKWebView.takeSnapshot`, `webkit_web_view_get_snapshot`,
    /// `ICoreWebView2.CapturePreview`.
    ///
    /// Used by the app driver's `screenshot` verb. Backends that can't
    /// snapshot leave the default in place, which throws
    /// `E_UNIMPLEMENTED`; check ``supportsSnapshot`` first to get a clean
    /// "unsupported here" rather than a failed call.
    func captureSnapshot() async throws -> Data

    /// Whether ``captureSnapshot()`` is implemented on this backend.
    ///
    /// A separate flag rather than a `try?` probe because the driver's
    /// `capabilities` verb has to answer *before* anyone asks for pixels,
    /// and "call it and see" would mean rendering a snapshot to find out.
    var supportsSnapshot: Bool { get }

    /// Deliver a synthetic pointer / key / wheel event into this webview.
    ///
    /// Into the app's **own** event queue, never the OS-wide HID tap — see
    /// ``SyntheticInput`` for why that distinction is the whole point. Backends
    /// that can't synthesize events leave the default in place, which throws
    /// `E_UNIMPLEMENTED`; consult ``inputCapabilities`` first.
    func send(_ input: SyntheticInput) async throws

    /// What ``send(_:)`` can actually express here. Same reasoning as
    /// ``supportsSnapshot``, but structured: "can click" and "can deliver a
    /// stylus event with pressure and tilt" are different questions, and a
    /// stylus test that silently ran as a mouse click would pass while proving
    /// nothing.
    var inputCapabilities: InputCapabilities { get }
}

public extension PWAWebView {
    func openDevTools() {} // default: no-op

    func captureSnapshot() async throws -> Data {
        throw BridgeError(
            code: BridgeError.unimplemented,
            message: "this backend can't snapshot its webview contents"
        )
    }

    var supportsSnapshot: Bool {
        false
    }

    func send(_: SyntheticInput) async throws {
        throw BridgeError(
            code: BridgeError.unimplemented,
            message: "this backend can't synthesize input events"
        )
    }

    var inputCapabilities: InputCapabilities {
        .none
    }
}
