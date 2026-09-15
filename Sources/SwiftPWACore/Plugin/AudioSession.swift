import Foundation

/// The platform's audio *session* policy — what the app's audio means relative
/// to everything else playing on the device.
///
/// This is the native half of the **W3C Audio Session API**, not a new surface.
/// Apple's WebKit already ships `navigator.audioSession`; no other engine this
/// project runs on does (measured on all five — see
/// [`docs/proposals/audio-plugin.md`](../../../docs/proposals/audio-plugin.md)).
/// So `bridge.js` polyfills the web API where it's missing and routes it here,
/// and an adopting app writes the one standard line either way:
///
/// ```js
/// navigator.audioSession.type = 'playback';   // or 'ambient' for a game
/// ```
///
/// Why it's worth having at all: the type decides whether the app's audio
/// ducks the user's music or mixes with it, whether it survives the app going
/// to the background, and on iOS whether the page keeps running to *generate*
/// more. An app that never sets it works in every foreground test and fails
/// only on a backgrounded phone — which is exactly the kind of gap an adopter
/// without that device can't find.
public protocol AudioSession: AnyObject, Sendable {
    /// Apply `type` as the app's audio session policy.
    ///
    /// Idempotent: setting the same type twice is not an error, because the
    /// page may re-assert it on every play.
    func setType(_ type: AudioSessionType) async throws

    /// The type currently in force, as the *platform* understands it — which
    /// may not be what was last set if the OS overrode it.
    func currentType() async throws -> AudioSessionType

    /// Whether the app currently holds the audio focus its type asked for.
    func state() async throws -> AudioSessionState
}

/// The W3C `AudioSessionType` values, spelled exactly as the web API spells
/// them so the polyfill passes them through untranslated.
public enum AudioSessionType: String, Sendable, Codable, CaseIterable {
    /// Let the engine decide. The default, and what an app that never sets a
    /// type gets.
    case auto
    /// Background music, a podcast, read-aloud: keeps playing when the app
    /// isn't in front, and interrupts other audio rather than mixing with it.
    case playback
    /// Game or UI audio: mixes with whatever the user is already listening to
    /// rather than stopping it, and is silenced by the mute switch.
    case ambient
    /// A short sound that ducks other audio for its duration.
    case transient
    /// A short sound that silences other audio for its duration.
    case transientSolo = "transient-solo"
    /// Simultaneous capture and playback — a call, or live transcription with
    /// audible feedback.
    case playAndRecord = "play-and-record"
}

/// The W3C `AudioSessionState` values.
public enum AudioSessionState: String, Sendable, Codable {
    /// Nothing is playing and no focus is held.
    case inactive
    /// The app holds focus and may play.
    case active
    /// Something else took focus — a call, another app. Playback should pause
    /// and may resume when focus returns.
    case interrupted
}

// MARK: - DTOs (used by `AudioSessionPlugin`)

public struct AudioSessionSetArgs: Sendable, Codable, Equatable {
    public var type: String
    public init(type: String) { self.type = type }
}

public struct AudioSessionStatus: Sendable, Codable, Equatable {
    public var type: String
    public var state: String
    public init(type: String, state: String) {
        self.type = type
        self.state = state
    }
}
