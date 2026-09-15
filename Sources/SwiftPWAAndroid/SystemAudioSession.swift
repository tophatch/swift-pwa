#if os(Android)
    import Foundation
    import SwiftPWACore

    /// Android's half of the `navigator.audioSession` polyfill, over
    /// `AudioManager` audio focus.
    ///
    /// **What the type can and cannot control here**, because the limit is not
    /// obvious: the WebView plays through its own audio track with its own
    /// attributes, which the app doesn't get to rewrite. What the app *can* do
    /// is hold — or decline to hold — audio focus on the session's behalf, and
    /// that is what decides the observable behaviour the API is about: whether
    /// the user's music is paused, ducked, or left alone while this app plays.
    ///
    /// So `ambient` isn't "mix" spelled a different way — it is *not asking for
    /// focus at all*, which is what leaves other audio playing. The mapping:
    ///
    /// | type | focus request |
    /// | --- | --- |
    /// | `playback` | `AUDIOFOCUS_GAIN` — other audio stops |
    /// | `play-and-record` | `AUDIOFOCUS_GAIN` with voice-communication usage |
    /// | `transient` | `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` — other audio ducks |
    /// | `transient-solo` | `AUDIOFOCUS_GAIN_TRANSIENT` — other audio pauses |
    /// | `ambient` / `auto` | none; focus is abandoned if held |
    public final class SystemAudioSession: AudioSession {
        public init() {}

        public func setType(_ type: AudioSessionType) async throws {
            _ = try await AndroidRPC.call(
                "audio.session.set",
                AudioSessionSetArgs(type: type.rawValue),
                as: AudioSessionStatus.self
            )
        }

        public func currentType() async throws -> AudioSessionType {
            let status = try await AndroidRPC.call(
                "audio.session.get",
                EmptyArgs(),
                as: AudioSessionStatus.self
            )
            // An unrecognised spelling degrades to `.auto` rather than throwing:
            // the page is reading a property, and a getter that throws would be
            // a far stranger failure than one reporting the default.
            return AudioSessionType(rawValue: status.type) ?? .auto
        }

        public func state() async throws -> AudioSessionState {
            let status = try await AndroidRPC.call(
                "audio.session.get",
                EmptyArgs(),
                as: AudioSessionStatus.self
            )
            return AudioSessionState(rawValue: status.state) ?? .inactive
        }
    }
#endif
