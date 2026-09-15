import Foundation

/// Built-in plugin backing the **`navigator.mediaSession` polyfill** in
/// `bridge.js`, installed only by backends whose engine lacks the web API —
/// which, measured across all five, means Android alone.
///
/// The commands are `__audio.*`, runtime-internal like `__platform.info`;
/// nothing in an app calls them directly.
///
/// User-triggered transport actions travel the other way, over the runtime's
/// own event bus on the `__audio.action` channel, because that is the one
/// push primitive every window already receives. The polyfill subscribes and
/// dispatches to whichever handler the page registered.
public struct NowPlayingPlugin: Plugin {
    public static let pluginName = "__audio.nowPlaying"

    /// The channel user-triggered transport actions arrive on. Shared with the
    /// polyfill in `bridge.js`, and asserted equal by a test — two string
    /// literals in two languages can only drift silently.
    public static let actionChannel = "__audio.action"

    private let nowPlaying: any NowPlaying

    public init(_ nowPlaying: any NowPlaying) {
        self.nowPlaying = nowPlaying
    }

    public func register(into registry: CommandRegistry, app: any AppContext) {
        let nowPlaying = nowPlaying

        registry.register(
            "__audio.nowPlaying.setMetadata",
            typed: { (args: NowPlayingMetadataArgs, _) async throws -> EmptyResult in
                try await nowPlaying.setMetadata(args.metadata)
                return EmptyResult()
            }
        )

        registry.register(
            "__audio.nowPlaying.setPlaybackState",
            typed: { (args: NowPlayingStateArgs, _) async throws -> EmptyResult in
                guard let state = NowPlayingPlaybackState(rawValue: args.state) else {
                    throw BridgeError(
                        code: BridgeError.decode,
                        message: "'\(args.state)' is not a playback state (none, paused, playing)."
                    )
                }
                try await nowPlaying.setPlaybackState(state)
                return EmptyResult()
            }
        )

        registry.register(
            "__audio.nowPlaying.setActions",
            typed: { (args: NowPlayingActionsArgs, _) async throws -> EmptyResult in
                // Unknown action names are dropped rather than refused: the spec
                // has actions no transport row can show, and a page registering
                // a handler for one shouldn't fail the whole call.
                let actions = args.actions.compactMap(NowPlayingAction.init(rawValue:))
                try await nowPlaying.setSupportedActions(actions)
                return EmptyResult()
            }
        )

        registry.register(
            "__audio.nowPlaying.setPosition",
            typed: { (args: NowPlayingPositionArgs, _) async throws -> EmptyResult in
                try await nowPlaying.setPosition(args.position)
                return EmptyResult()
            }
        )

        // Forward OS-triggered actions to every window. Started once, at
        // registration, and deliberately not tied to a subscription: the user
        // can press pause on the lock screen before the page has ever called
        // into this plugin.
        // `Task.detached`, not `Task` — and this is the difference between the
        // lock-screen buttons working and silently doing nothing. `register` is
        // `@MainActor`, so a plain `Task` inherits that isolation; on Android
        // the main thread runs a Java looper that never drains libdispatch's
        // main queue, so such a task is created and never scheduled. The same
        // hazard is why `BridgeRuntime` isn't `@MainActor` (see CLAUDE.md's
        // concurrency notes) — it bites identically here, and the symptom is
        // an action the OS delivers, Kotlin forwards and Swift yields, with
        // nothing at the other end.
        let events = app.events
        Task.detached {
            for await action in nowPlaying.actions() {
                let payload = NowPlayingActionEvent(action: action.rawValue)
                guard let data = try? JSONEncoder().encode(payload) else { continue }
                events.emit(Self.actionChannel, payload: data)
            }
        }
    }
}
