import Foundation
import SwiftPWACore

/// In-memory `WebView` for unit testing the bridge layer end-to-end
/// without spinning up a real `WKWebView` / `WebKitWebView`.
@MainActor
public final class MockWebView: PWAWebView {
    private var content: WindowContent?

    /// Frames the webview has been asked to deliver to JS. Tests assert
    /// against this array.
    public private(set) var deliveredFrames: [OutboundFrame] = []

    /// JS snippets passed to `evaluateJavaScript`. The first matching
    /// entry in `evaluationResults` (if any) is consumed and returned.
    public private(set) var evaluatedScripts: [String] = []
    public var evaluationResults: [String?] = []

    private var inboundContinuation: AsyncStream<InboundFrame>.Continuation?
    private lazy var inboundStream: AsyncStream<InboundFrame> = AsyncStream { continuation in
        self.inboundContinuation = continuation
    }

    public init() {}

    /// Inject a frame as if it had arrived from the JS side.
    public func send(_ frame: InboundFrame) {
        _ = inboundStream // ensure continuation has been captured
        inboundContinuation?.yield(frame)
    }

    /// Convenience: build and send an `invoke` frame from a typed payload.
    public func sendInvoke(id: UInt64, command: String, payload: some Encodable) throws {
        let data = try JSONEncoder().encode(payload)
        send(.invoke(id: id, command: command, payload: data))
    }

    public func sendSubscribe(id: UInt64, command: String, payload: some Encodable) throws {
        let data = try JSONEncoder().encode(payload)
        send(.subscribe(id: id, command: command, payload: data))
    }

    public func endInbound() { inboundContinuation?.finish() }

    // MARK: - WebView

    public func load(_ content: WindowContent) {
        self.content = content
    }

    public func evaluateJavaScript(_ js: String) async throws -> String? {
        evaluatedScripts.append(js)
        guard !evaluationResults.isEmpty else { return nil }
        return evaluationResults.removeFirst()
    }

    public func deliver(_ frame: OutboundFrame) async throws {
        deliveredFrames.append(frame)
    }

    public func inboundFrames() -> AsyncStream<InboundFrame> {
        inboundStream
    }
}
