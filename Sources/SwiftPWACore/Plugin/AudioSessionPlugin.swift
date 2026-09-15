import Foundation

/// Built-in plugin backing the **`navigator.audioSession` polyfill** in
/// `bridge.js` on the platforms whose engine doesn't ship the web API.
///
/// Registered eagerly by the backends that have an implementation, like
/// `WindowPlugin` / `EventsPlugin` — never opt-in. An adopter's whole
/// requirement is the standard web line (`navigator.audioSession.type =
/// 'playback'`); asking them to install a plugin to make a *standard API* work
/// would defeat the point.
///
/// The commands are `__audio.*` — the double-underscore prefix marks them as
/// runtime-internal, like `__platform.info` and `__bridge.describe`. Nothing in
/// an app should call them directly, and their shape is free to change with the
/// polyfill that consumes them.
///
/// On Apple both platforms already implement `navigator.audioSession` natively,
/// so the polyfill never installs there and these commands are simply unused.
public struct AudioSessionPlugin: Plugin {
    public static let pluginName = "__audio"

    private let session: any AudioSession

    public init(_ session: any AudioSession) {
        self.session = session
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let session = session

        // Set + read back in one round trip. The polyfill assigns to a
        // property, which can't await, so it fires this and reconciles when the
        // reply lands — reading the *platform's* answer rather than echoing the
        // request means an OS that refused or coerced the type shows up as the
        // type the page can actually observe.
        registry.register(
            "__audio.session.set",
            typed: { (args: AudioSessionSetArgs, _) async throws -> AudioSessionStatus in
                guard let type = AudioSessionType(rawValue: args.type) else {
                    throw BridgeError(
                        code: BridgeError.decode,
                        message: """
                        '\(args.type)' is not an audio session type. Valid: \
                        \(AudioSessionType.allCases.map(\.rawValue).joined(separator: ", ")).
                        """
                    )
                }
                try await session.setType(type)
                return try await AudioSessionStatus(
                    type: session.currentType().rawValue,
                    state: session.state().rawValue
                )
            }
        )

        registry.register(
            "__audio.session.get",
            typed: { (_: EmptyArgs, _) async throws -> AudioSessionStatus in
                try await AudioSessionStatus(
                    type: session.currentType().rawValue,
                    state: session.state().rawValue
                )
            }
        )
    }
}
