import Foundation

/// What the OS shows and offers for the audio this app is playing — the lock
/// screen entry, the notification, the media keys.
///
/// This is the native half of the **W3C Media Session API**, not a new surface.
/// Four of the five engines already route `navigator.mediaSession` to the OS,
/// verified by driving the real control rather than by checking for the
/// property: a hardware media key on macOS and Windows, the lock screen on iOS,
/// an MPRIS `Pause` over D-Bus on both GTK backends. Android's embedded WebView
/// is the one that doesn't expose the API at all — so `bridge.js` fills it
/// there and routes to this.
///
/// Without it, an Android app playing audio is invisible to the system: no
/// lock-screen controls, no notification, and nothing tells the OS that audio
/// is playing at all.
public protocol NowPlaying: AnyObject, Sendable {
    /// Publish what's playing, or `nil` to clear it.
    func setMetadata(_ metadata: NowPlayingMetadata?) async throws

    /// Tell the OS whether this is playing, paused, or nothing.
    func setPlaybackState(_ state: NowPlayingPlaybackState) async throws

    /// Declare which transport controls the page can handle. The OS shows only
    /// the ones named here, which is why it's a set rather than a fixed row:
    /// offering a "next track" button that does nothing is worse than not
    /// offering it.
    func setSupportedActions(_ actions: [NowPlayingAction]) async throws

    /// Publish the playback position, so a scrubber can be drawn. `nil` clears
    /// it.
    func setPosition(_ position: NowPlayingPosition?) async throws

    /// A stream of transport actions the *user* triggered from the OS — the
    /// lock screen, a headset button, a media key. These are delivered to the
    /// page's registered handler.
    func actions() -> AsyncStream<NowPlayingAction>
}

public struct NowPlayingMetadata: Sendable, Codable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
    }
}

/// The W3C `MediaSessionPlaybackState` values, spelled as the web API spells
/// them so the polyfill passes them through untranslated.
public enum NowPlayingPlaybackState: String, Sendable, Codable, CaseIterable {
    case none
    case paused
    case playing
}

/// The subset of W3C `MediaSessionAction` a transport control can carry.
///
/// Deliberately not the full list: the spec includes actions with no place in
/// an OS transport row (`skipad`, `togglecamera`). These are the ones every
/// platform's lock screen can actually show.
public enum NowPlayingAction: String, Sendable, Codable, CaseIterable {
    case play
    case pause
    case stop
    case previousTrack = "previoustrack"
    case nextTrack = "nexttrack"
    case seekBackward = "seekbackward"
    case seekForward = "seekforward"
    case seekTo = "seekto"
}

public struct NowPlayingPosition: Sendable, Codable, Equatable {
    /// Seconds.
    public var duration: Double
    /// Seconds.
    public var position: Double
    public var playbackRate: Double

    public init(duration: Double, position: Double, playbackRate: Double = 1) {
        self.duration = duration
        self.position = position
        self.playbackRate = playbackRate
    }
}

// MARK: - DTOs (used by `NowPlayingPlugin`)

public struct NowPlayingMetadataArgs: Sendable, Codable, Equatable {
    public var metadata: NowPlayingMetadata?
    public init(metadata: NowPlayingMetadata?) { self.metadata = metadata }
}

public struct NowPlayingStateArgs: Sendable, Codable, Equatable {
    public var state: String
    public init(state: String) { self.state = state }
}

public struct NowPlayingActionsArgs: Sendable, Codable, Equatable {
    public var actions: [String]
    public init(actions: [String]) { self.actions = actions }
}

public struct NowPlayingPositionArgs: Sendable, Codable, Equatable {
    public var position: NowPlayingPosition?
    public init(position: NowPlayingPosition?) { self.position = position }
}

public struct NowPlayingActionEvent: Sendable, Codable, Equatable {
    public var action: String
    public init(action: String) { self.action = action }
}
