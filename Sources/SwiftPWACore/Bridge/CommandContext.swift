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

    /// For a duplex-session command (`registerSession`), the client→server
    /// inbound side. `nil` for ordinary `invoke` / `subscribe` dispatch.
    /// Threaded in by `BridgeRuntime`, which owns the continuation and routes
    /// `push` frames to it; `registerSession`'s typed wrapper decodes it into a
    /// `BridgeInbound<Frame>`.
    public let sessionInbound: SessionInbound?

    public init(
        invocation: Invocation,
        originWindow: WindowID?,
        appContext: any AppContext,
        sessionInbound: SessionInbound? = nil
    ) {
        self.invocation = invocation
        self.originWindow = originWindow
        self.appContext = appContext
        self.sessionInbound = sessionInbound
    }
}

/// The client→server inbound side of an open duplex session, threaded onto
/// `CommandContext` by `BridgeRuntime`. Carries the raw pushed-frame payloads
/// plus a live accessor for how many were dropped because the bounded buffer
/// overflowed (drop-oldest). Typed handlers consume this indirectly through
/// `BridgeInbound<Frame>`; the raw `frames` are available for a bytes-level
/// handler.
public struct SessionInbound: Sendable {
    /// Raw JSON payloads of client `push` frames, in send order.
    public let frames: AsyncStream<Data>
    private let dropCount: @Sendable () -> Int

    /// Number of client frames dropped so far because the buffer was full.
    public var droppedCount: Int {
        dropCount()
    }

    public init(frames: AsyncStream<Data>, droppedCount: @escaping @Sendable () -> Int) {
        self.frames = frames
        dropCount = droppedCount
    }
}
