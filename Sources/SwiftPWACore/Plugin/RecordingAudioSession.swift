import Foundation

/// The desktop `AudioSession`: it records the type and reports it back, and
/// does **not** drive any platform mechanism — because on Linux and Windows
/// there isn't one for an embedder to drive.
///
/// That claim is measured, not assumed, and it is the reason this type exists
/// instead of a real implementation:
///
/// - **The audio isn't ours.** The playing stream belongs to the webview's own
///   process, not the app's — `WebKitWebProcess` on Linux (PipeWire reports the
///   node's `application.process.binary`), `msedgewebview2.exe` on Windows.
///   Both platforms set session policy *per stream, by the stream's creator*,
///   so the app has nothing to set. Android is the opposite and that's why the
///   fill works there: `AudioManager` focus is per-*uid*, so the app can hold
///   focus on the webview's behalf.
/// - **Nothing consumes the knob anyway** on a stock Linux desktop. WebKit
///   already tags its stream `media.role: Music`, and a default GNOME/PipeWire
///   session loads no role-ducking or role-cork module at all — so a role is
///   inert there regardless of who sets it.
/// - **And the behaviours the type exists to fix aren't broken here.** Measured
///   on GTK3, GTK4 and WebView2: a minimized window keeps its audio clock and
///   its media element running. The background-suspension problem `playback`
///   solves is an iOS problem.
///
/// So the honest shape is a uniform *API* with a documented per-platform
/// *effect*: a page sets `navigator.audioSession.type` once and never branches,
/// and the docs say where it changes what the OS does. Reporting a state it
/// hasn't got would be worse than doing nothing — an app would pause on a
/// `interrupted` that can never arrive, or trust a `playback` that bought it
/// nothing.
///
/// If a desktop platform grows an app-level audio session concept, this is the
/// one place to replace.
public final class RecordingAudioSession: AudioSession, @unchecked Sendable {
    private let lock = NSLock()
    private var type: AudioSessionType = .auto

    public init() {}

    public func setType(_ type: AudioSessionType) async throws {
        lock.withLock { self.type = type }
    }

    public func currentType() async throws -> AudioSessionType {
        lock.withLock { type }
    }

    /// Mirrors the mapping the platforms *with* a session concept use, so a page
    /// reads the same thing everywhere: a type that means "I am playing" reports
    /// `active`, and `ambient`/`auto` — which on Android deliberately hold no
    /// focus — report `inactive`.
    ///
    /// `interrupted` is never reported here, because nothing on these platforms
    /// interrupts an app's audio the way a phone call does.
    public func state() async throws -> AudioSessionState {
        switch lock.withLock({ type }) {
        case .playback, .playAndRecord, .transient, .transientSolo: .active
        case .ambient, .auto: .inactive
        }
    }
}
