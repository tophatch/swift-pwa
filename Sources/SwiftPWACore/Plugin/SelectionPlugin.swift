import Foundation

/// Built-in plugin for the page's part in the platform's text-selection UI:
///
/// - `selection.setActions` — add the page's own items to the system
///   selection menu (#352).
/// - `selection.subscribe` — the items chosen, and when a selection gesture
///   begins and ends (#353), for the calling window.
///
/// Events are per window, not on the app-wide ``EventBus``: a selection
/// belongs to one webview, and a second window must not act on a choice made
/// in the first.
public struct SelectionPlugin: Plugin {
    public static let pluginName = "selection"

    /// The command `bridge.js` reports a mouse selection gesture on. A mouse
    /// press is visible to the page as `pointerdown` / `pointerup`, so the
    /// page side sees it first; routing it through the webview's
    /// ``WebViewSelection`` keeps one stream for the page whatever the input.
    public static let pointerGestureCommand = "__selection.pointerGesture"

    public init() {}

    public func register(into registry: CommandRegistry, app: any AppContext) {
        registry.register(
            "selection.setActions",
            typed: { (args: SelectionSetActionsArgs, ctx) async throws -> EmptyResult in
                let selection = try await Self.selection(ctx: ctx, app: app)
                try await selection.setActions(args.actions)
                return EmptyResult()
            }
        )

        registry.register(
            Self.pointerGestureCommand,
            typed: { (args: SelectionPointerGestureArgs, ctx) async throws -> EmptyResult in
                let selection = try await Self.selection(ctx: ctx, app: app)
                selection.gesture(args.phase)
                return EmptyResult()
            }
        )

        registry.registerStream(
            "selection.subscribe",
            typed: { (_: EmptyArgs, ctx) -> AsyncThrowingStream<SelectionEvent, any Error> in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        let selection: WebViewSelection
                        do {
                            selection = try await Self.selection(ctx: ctx, app: app)
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                        for await event in selection.events() {
                            if Task.isCancelled { break }
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
    }

    private static func selection(ctx: CommandContext, app: any AppContext) async throws -> WebViewSelection {
        let target = ctx.originWindow
        let selection: WebViewSelection?? = await MainThread.run {
            target.flatMap { app.window($0) }.map(\.webView.selection)
        }
        guard let found = selection else {
            throw BridgeError(code: BridgeError.notFound, message: "selection.* is only available to a window's page")
        }
        guard let found else {
            throw BridgeError(
                code: BridgeError.unimplemented,
                message: "this backend can't reach its text-selection menu"
            )
        }
        return found
    }
}

public struct SelectionSetActionsArgs: Sendable, Codable {
    public var actions: [SelectionAction]
    public init(actions: [SelectionAction]) { self.actions = actions }
}

public struct SelectionPointerGestureArgs: Sendable, Codable {
    public var phase: SelectionGesturePhase
    public init(phase: SelectionGesturePhase) { self.phase = phase }
}
