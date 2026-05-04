import Foundation

/// Cross-platform webview contract. Backends wrap `WKWebView` /
/// `WebKitWebView` and provide:
///   - the channel used to receive `InboundFrame`s from JS
///   - a way to send `OutboundFrame`s to JS (typically via injected JS
///     that calls a global resolver table)
///   - script evaluation / loading primitives.
@MainActor
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
}
