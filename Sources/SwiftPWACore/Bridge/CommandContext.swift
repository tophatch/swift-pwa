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

    public init(
        invocation: Invocation,
        originWindow: WindowID?,
        appContext: any AppContext
    ) {
        self.invocation = invocation
        self.originWindow = originWindow
        self.appContext = appContext
    }
}
