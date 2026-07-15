import Foundation

/// Per-invocation context handed to a registered command handler.
///
/// Holds the `Invocation` itself plus a `WindowID?` indicating which
/// window's webview originated the call (so window.* commands can target
/// the right window without the JS side having to pass the id explicitly).
///
/// `appContext` is `@MainActor` isolated; handlers must hop to MainActor
/// before touching it. Held as `any AppContext` so `_SwiftPWATestSupport`
/// can supply a mock.
public struct CommandContext: Sendable {
    public let invocation: Invocation
    public let originWindow: WindowID?
    public let appContext: any AppContext

    /// For a duplex-session command (`registerSession`), the stream of raw
    /// client frame payloads pushed into this open session via `push`. `nil`
    /// for ordinary `invoke` / `subscribe` dispatch. Threaded in by
    /// `BridgeRuntime`, which owns the continuation and routes `push` frames
    /// to it; `registerSession`'s typed wrapper decodes it into a
    /// `BridgeInbound<Frame>`.
    public let sessionInbound: AsyncStream<Data>?

    public init(
        invocation: Invocation,
        originWindow: WindowID?,
        appContext: any AppContext,
        sessionInbound: AsyncStream<Data>? = nil
    ) {
        self.invocation = invocation
        self.originWindow = originWindow
        self.appContext = appContext
        self.sessionInbound = sessionInbound
    }
}
