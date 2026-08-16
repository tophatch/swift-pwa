import Foundation
import SwiftPWACore

/// In-memory `PWAWebView` for unit testing the bridge layer end-to-end
/// without spinning up a real `WKWebView` / `WebKitWebView`.
///
/// Not `@MainActor` (the real backends aren't either). State is
/// guarded by an internal lock since tests may push frames while the
/// bridge runtime pumps from a cooperative-pool task.
public final class MockWebView: PWAWebView, @unchecked Sendable {
    private let lock = NSLock()
    private var content: WindowContent?
    private var _deliveredFrames: [OutboundFrame] = []
    private var _evaluatedScripts: [String] = []
    private var _evaluationResults: [String?] = []

    /// Frames the webview has been asked to deliver to JS. Tests assert
    /// against this array.
    public var deliveredFrames: [OutboundFrame] {
        lock.withLock { _deliveredFrames }
    }

    /// JS snippets passed to `evaluateJavaScript`.
    public var evaluatedScripts: [String] {
        lock.withLock { _evaluatedScripts }
    }

    /// Tests can preload return values for `evaluateJavaScript`. Each
    /// `evaluateJavaScript` call consumes one entry, in order.
    public var evaluationResults: [String?] {
        get { lock.withLock { _evaluationResults } }
        set { lock.withLock { _evaluationResults = newValue } }
    }

    /// What this mock claims it can synthesize. Defaults to nothing — the same
    /// answer a backend without event synthesis gives — so a test that wants
    /// the input path has to opt in and say what it's pretending to support.
    public var stubbedInputCapabilities: InputCapabilities {
        get { lock.withLock { _inputCapabilities } }
        set { lock.withLock { _inputCapabilities = newValue } }
    }

    /// Events handed to ``send(_:)``, in order.
    public var receivedInput: [SyntheticInput] {
        lock.withLock { _receivedInput }
    }

    private var _inputCapabilities: InputCapabilities = .none
    private var _receivedInput: [SyntheticInput] = []

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

    /// Close an open subscription or session, as `unsubscribe()` / `close()`
    /// does from JS — the path a handler's teardown (`onTermination`) runs on.
    public func sendUnsubscribe(id: UInt64) {
        send(.unsubscribe(id: id))
    }

    /// Convenience: build and send a `push` frame (a client frame into an open
    /// duplex session) from a typed payload.
    public func sendPush(id: UInt64, payload: some Encodable) throws {
        let data = try JSONEncoder().encode(payload)
        send(.push(id: id, payload: data))
    }

    public func endInbound() { inboundContinuation?.finish() }

    // MARK: - PWAWebView

    public func load(_ content: WindowContent) {
        lock.withLock { self.content = content }
    }

    public func evaluateJavaScript(_ js: String) async throws -> String? {
        lock.withLock {
            _evaluatedScripts.append(js)
            return _evaluationResults.isEmpty ? nil : _evaluationResults.removeFirst()
        }
    }

    public func deliver(_ frame: OutboundFrame) async throws {
        lock.withLock { _deliveredFrames.append(frame) }
    }

    public func inboundFrames() -> AsyncStream<InboundFrame> {
        inboundStream
    }

    public var inputCapabilities: InputCapabilities {
        stubbedInputCapabilities
    }

    public func send(_ input: SyntheticInput) async throws {
        lock.withLock { _receivedInput.append(input) }
    }
}
