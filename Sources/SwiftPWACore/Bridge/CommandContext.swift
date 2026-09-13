import Foundation

/// Who is on the other end of a command call.
///
/// A handler that wants to answer an agent more narrowly than it answers the
/// app's own page switches on this. It exists because the distinction used to
/// be readable only as `originWindow == nil`, which is a coincidence of the
/// agent path rather than a contract — and a coincidence fails *open*: give
/// agent calls a window id one day and every guard built on it silently stops
/// filtering, with no error and no warning.
///
/// There is deliberately no `driver` case. `swift-pwa drive eval` runs its
/// JavaScript inside the page, so a driven call arrives through the page's own
/// message handler with the page's window id and is not distinguishable here.
/// A case that can never be constructed would read like a filter that works.
public enum CommandCaller: Sendable, Equatable {
    /// The app's own web content, in the named window.
    case page(WindowID)
    /// A connected agent, through `AgentPlugin`'s exposed tool surface.
    case agent
}

/// Per-invocation context handed to a registered command handler.
///
/// Holds the `Invocation` itself plus the `caller` it came from (so `window.*`
/// commands can target the originating window without the JS side passing an
/// id, and so a handler can answer an agent differently from a page).
///
/// `appContext` is `@MainActor` isolated; handlers must hop to MainActor
/// before touching it. Held as `any AppContext` so `_SwiftPWATestSupport`
/// can supply a mock.
public struct CommandContext: Sendable {
    public let invocation: Invocation
    public let caller: CommandCaller
    /// Which frame of the page made the call — the app's own top-level
    /// document, an embedded one, or ``CallerFrame/unknown`` where the backend
    /// can't tell (both GTK backends) or there is no frame at all (an agent).
    ///
    /// Separate from ``caller`` rather than folded into `.page` because most
    /// handlers have no business caring, while the ones that do — anything
    /// handing a capability to the page — need it at the same moment they
    /// already have the context. See ``CallerFrame`` for why it isn't taken
    /// from the page's own word for it.
    public let frame: CallerFrame
    public let appContext: any AppContext

    /// The window whose webview originated the call, or `nil` for a caller
    /// that has no window. Derived from `caller`, so it can't drift from it.
    public var originWindow: WindowID? {
        guard case let .page(id) = caller else { return nil }
        return id
    }

    /// For a duplex-session command (`registerSession`), the client→server
    /// inbound side. `nil` for ordinary `invoke` / `subscribe` dispatch.
    /// Threaded in by `BridgeRuntime`, which owns the continuation and routes
    /// `push` frames to it; `registerSession`'s typed wrapper decodes it into a
    /// `BridgeInbound<Frame>`.
    public let sessionInbound: SessionInbound?

    public init(
        invocation: Invocation,
        caller: CommandCaller,
        frame: CallerFrame = .unknown,
        appContext: any AppContext,
        sessionInbound: SessionInbound? = nil
    ) {
        self.invocation = invocation
        self.caller = caller
        self.frame = frame
        self.appContext = appContext
        self.sessionInbound = sessionInbound
    }

    /// Source compatibility for code written against the pre-`caller` shape.
    /// Maps a window id to `.page` and `nil` to `.agent`, which is what the
    /// runtime actually passed — but only the runtime ever knew that, which is
    /// the reason `caller` exists.
    @available(*, deprecated, message: "Pass `caller:` — .page(id) or .agent — instead of `originWindow:`.")
    public init(
        invocation: Invocation,
        originWindow: WindowID?,
        appContext: any AppContext,
        sessionInbound: SessionInbound? = nil
    ) {
        self.init(
            invocation: invocation,
            caller: originWindow.map(CommandCaller.page) ?? .agent,
            appContext: appContext,
            sessionInbound: sessionInbound
        )
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
