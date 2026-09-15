#if os(Android)
    import Foundation
    import SwiftPWACore

    /// Android's half of the `navigator.mediaSession` polyfill, over the
    /// platform `MediaSession` and a `Notification.MediaStyle`.
    ///
    /// Actions travel the opposite way to everything else here: the user
    /// presses pause on the lock screen, Kotlin's `MediaSession.Callback` fires,
    /// and the event arrives over the host-event channel rather than as the
    /// reply to anything. That's why this holds a stream instead of answering
    /// calls — nothing on the JS side asked, and the press can land before the
    /// page has set any metadata at all.
    public final class SystemNowPlaying: NowPlaying, @unchecked Sendable {
        /// Matches the `channel` Kotlin stamps on the event.
        private static let hostChannel = "audio.nowPlaying.action"

        private let stream: AsyncStream<NowPlayingAction>
        private let continuation: AsyncStream<NowPlayingAction>.Continuation

        public init() {
            (stream, continuation) = AsyncStream<NowPlayingAction>.makeStream()

            let continuation = continuation
            AndroidHostEventRouter.subscribe(channel: Self.hostChannel) { data in
                guard let event = try? JSONDecoder().decode(HostAction.self, from: data),
                      let action = NowPlayingAction(rawValue: event.action)
                else { return }
                continuation.yield(action)
            }
        }

        private struct HostAction: Decodable {
            let action: String
        }

        public func setMetadata(_ metadata: NowPlayingMetadata?) async throws {
            try await AndroidRPC.callVoidWith(
                "audio.nowPlaying.setMetadata",
                NowPlayingMetadataArgs(metadata: metadata)
            )
        }

        public func setPlaybackState(_ state: NowPlayingPlaybackState) async throws {
            try await AndroidRPC.callVoidWith(
                "audio.nowPlaying.setPlaybackState",
                NowPlayingStateArgs(state: state.rawValue)
            )
        }

        public func setSupportedActions(_ actions: [NowPlayingAction]) async throws {
            try await AndroidRPC.callVoidWith(
                "audio.nowPlaying.setActions",
                NowPlayingActionsArgs(actions: actions.map(\.rawValue))
            )
        }

        public func setPosition(_ position: NowPlayingPosition?) async throws {
            try await AndroidRPC.callVoidWith(
                "audio.nowPlaying.setPosition",
                NowPlayingPositionArgs(position: position)
            )
        }

        public func actions() -> AsyncStream<NowPlayingAction> { stream }
    }

    extension AndroidRPC {
        /// `callVoid` takes no arguments and `call` insists on a result; these
        /// handlers take arguments and return nothing.
        static func callVoidWith(_ method: String, _ args: some Encodable) async throws {
            _ = try await call(method, args, as: NoResult.self)
        }
    }
#endif
