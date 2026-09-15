import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// The `__audio.*` commands behind the `navigator.audioSession` polyfill.
///
/// The behaviour these pin down is *parity with WebKit's real implementation*,
/// measured on macOS and iOS rather than read off the spec: an unrecognised
/// type is ignored, and reading back reports what the platform did rather than
/// what the page asked for. A polyfill that diverges from the engine it's
/// imitating is worse than no polyfill, because an app then behaves one way on
/// Apple and another everywhere else — the exact split this exists to prevent.
@Suite("AudioSessionPlugin")
@MainActor
struct AudioSessionPluginTests {
    /// Records what was asked of it, and can pretend the platform coerced the
    /// type — which is the case the reply shape exists for.
    final class MockAudioSession: AudioSession, @unchecked Sendable {
        private let lock = NSLock()
        private var _type: AudioSessionType = .auto
        private var _state: AudioSessionState = .inactive
        private var _coerceTo: AudioSessionType?
        private var _setCalls: [AudioSessionType] = []

        init(coerceTo: AudioSessionType? = nil) { _coerceTo = coerceTo }

        var setCalls: [AudioSessionType] {
            lock.withLock { _setCalls }
        }

        func setType(_ type: AudioSessionType) async throws {
            lock.withLock {
                _setCalls.append(type)
                _type = _coerceTo ?? type
                // Only a type that asks for focus makes the session active —
                // `ambient` and `auto` deliberately hold none.
                _state = switch _type {
                case .playback, .playAndRecord, .transient, .transientSolo: .active
                case .ambient, .auto: .inactive
                }
            }
        }

        func currentType() async throws -> AudioSessionType { lock.withLock { _type } }
        func state() async throws -> AudioSessionState { lock.withLock { _state } }
    }

    private func makeApp(coerceTo: AudioSessionType? = nil) -> (MockAppContext, MockAudioSession) {
        let app = MockAppContext()
        let session = MockAudioSession(coerceTo: coerceTo)
        app.use(AudioSessionPlugin(session))
        return (app, session)
    }

    private func dispatch(
        _ app: MockAppContext,
        _ command: String,
        _ json: String = "{}"
    ) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: Data(json.utf8))
        let ctx = CommandContext(invocation: inv, caller: .agent, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    @Test("setting a type applies it and reports the resulting state")
    func setAppliesType() async throws {
        let (app, session) = makeApp()
        let result = await dispatch(app, "__audio.session.set", #"{"type":"playback"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let status = try JSONDecoder().decode(AudioSessionStatus.self, from: data)
        #expect(status.type == "playback")
        #expect(status.state == "active")
        #expect(session.setCalls == [.playback])
    }

    @Test("ambient holds no focus, so it reports inactive rather than active")
    func ambientHoldsNoFocus() async throws {
        let (app, _) = makeApp()
        let result = await dispatch(app, "__audio.session.set", #"{"type":"ambient"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let status = try JSONDecoder().decode(AudioSessionStatus.self, from: data)
        #expect(status.type == "ambient")
        // Not a detail: `ambient` is implemented as *declining* focus, which is
        // what leaves the user's own music playing. An `ambient` that reported
        // `active` would mean it had taken focus, i.e. the wrong behaviour.
        #expect(status.state == "inactive")
    }

    @Test("the reply reports what the platform did, not what was asked")
    func replyReportsPlatformTruth() async throws {
        // An OS that refuses `playback` and leaves the session on `ambient` has
        // to surface as `ambient`, or the page believes it has background audio
        // it doesn't have.
        let (app, _) = makeApp(coerceTo: .ambient)
        let result = await dispatch(app, "__audio.session.set", #"{"type":"playback"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let status = try JSONDecoder().decode(AudioSessionStatus.self, from: data)
        #expect(status.type == "ambient")
    }

    @Test("an unrecognised type is refused and never reaches the platform")
    func unknownTypeRefused() async {
        let (app, session) = makeApp()
        let result = await dispatch(app, "__audio.session.set", #"{"type":"nonsense"}"#)
        guard case let .failure(error) = result else {
            Issue.record("expected a failure for an unknown type")
            return
        }
        #expect(error.code == BridgeError.decode)
        #expect(session.setCalls.isEmpty)
    }

    @Test("every W3C type is accepted")
    func allTypesAccepted() async {
        for type in AudioSessionType.allCases {
            let (app, session) = makeApp()
            let result = await dispatch(app, "__audio.session.set", #"{"type":"\#(type.rawValue)"}"#)
            guard case .ok = result else {
                Issue.record("\(type.rawValue) was refused")
                continue
            }
            #expect(session.setCalls == [type])
        }
    }

    @Test("get reports the session without changing it")
    func getDoesNotMutate() async throws {
        let (app, session) = makeApp()
        _ = await dispatch(app, "__audio.session.set", #"{"type":"transient"}"#)
        let result = await dispatch(app, "__audio.session.get")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let status = try JSONDecoder().decode(AudioSessionStatus.self, from: data)
        #expect(status.type == "transient")
        #expect(session.setCalls == [.transient])
    }
}

/// The polyfill text itself, asserted against `bridge.js` rather than a copy.
///
/// These exist because the polyfill's contract is *silence*: an invalid
/// assignment does nothing, which is indistinguishable from the polyfill not
/// being installed at all. A regression that starts throwing — or starts
/// round-tripping every bad value to native — would pass every other test here.
@Suite("navigator.audioSession polyfill")
struct AudioSessionPolyfillTests {
    private var bridge: String {
        (try? BridgeScript.source()) ?? ""
    }

    @Test("the polyfill only installs where the engine lacks the API")
    func onlyWhenAbsent() {
        #expect(bridge.contains(#"!("audioSession" in navigator)"#))
    }

    @Test("invalid values are filtered in JS, not sent to native")
    func validatesLocally() {
        // WebIDL ignores an unrecognised enum value, and WebKit was measured
        // doing exactly that. Validating here keeps the polyfill's behaviour
        // identical without a round trip that could only answer too late.
        #expect(bridge.contains("const TYPES = new Set(["))
        #expect(bridge.contains("if (!TYPES.has(name)) return;"))
    }

    @Test("every W3C type the Swift enum knows is in the JS set")
    func typeListsAgree() {
        // Two lists of the same enum, in two languages, in two files. They can
        // only drift silently.
        for type in AudioSessionType.allCases {
            #expect(bridge.contains("\"\(type.rawValue)\""), "bridge.js is missing \(type.rawValue)")
        }
    }

    @Test("the polyfill calls the command the plugin registers")
    func commandNameAgrees() {
        #expect(bridge.contains(#"invoke("__audio.session.set""#))
    }
}

/// The desktop session: uniform API, no platform mechanism.
///
/// These pin the *honesty* of that choice. The temptation on a platform with
/// nothing to drive is to report whatever sounds healthiest; an app that acts
/// on `state` would then pause for an interruption that can never arrive, or
/// trust a `playback` that bought it nothing.
@Suite("RecordingAudioSession")
struct RecordingAudioSessionTests {
    @Test("it records and reports the type it was given")
    func recordsType() async throws {
        let session = RecordingAudioSession()
        #expect(try await session.currentType() == .auto)
        try await session.setType(.playback)
        #expect(try await session.currentType() == .playback)
    }

    @Test("state mirrors the platforms that do have a session concept")
    func stateMatchesAndroidMapping() async throws {
        let session = RecordingAudioSession()
        for type in [AudioSessionType.playback, .playAndRecord, .transient, .transientSolo] {
            try await session.setType(type)
            #expect(try await session.state() == .active, "\(type.rawValue) should read active")
        }
        // `ambient` and `auto` hold no focus on Android, so they must not claim
        // to be active here either — a page reading `state` should see the same
        // answer on every platform.
        for type in [AudioSessionType.ambient, .auto] {
            try await session.setType(type)
            #expect(try await session.state() == .inactive, "\(type.rawValue) should read inactive")
        }
    }

    @Test("it never reports interrupted, because nothing here interrupts")
    func neverInterrupted() async throws {
        let session = RecordingAudioSession()
        for type in AudioSessionType.allCases {
            try await session.setType(type)
            #expect(try await session.state() != .interrupted)
        }
    }
}

/// The `__audio.nowPlaying.*` commands behind the `navigator.mediaSession`
/// polyfill.
@Suite("NowPlayingPlugin")
@MainActor
struct NowPlayingPluginTests {
    final class MockNowPlaying: NowPlaying, @unchecked Sendable {
        private let lock = NSLock()
        private var _metadata: NowPlayingMetadata?
        private var _state: NowPlayingPlaybackState = .none
        private var _actions: [NowPlayingAction] = []
        private var _position: NowPlayingPosition?
        let continuation: AsyncStream<NowPlayingAction>.Continuation
        private let stream: AsyncStream<NowPlayingAction>

        init() { (stream, continuation) = AsyncStream<NowPlayingAction>.makeStream() }

        var metadata: NowPlayingMetadata? {
            lock.withLock { _metadata }
        }
        var state: NowPlayingPlaybackState {
            lock.withLock { _state }
        }
        var publishedActions: [NowPlayingAction] {
            lock.withLock { _actions }
        }
        var position: NowPlayingPosition? {
            lock.withLock { _position }
        }

        func setMetadata(_ metadata: NowPlayingMetadata?) async throws {
            lock.withLock { _metadata = metadata }
        }

        func setPlaybackState(_ state: NowPlayingPlaybackState) async throws {
            lock.withLock { _state = state }
        }

        func setSupportedActions(_ actions: [NowPlayingAction]) async throws {
            lock.withLock { _actions = actions }
        }

        func setPosition(_ position: NowPlayingPosition?) async throws {
            lock.withLock { _position = position }
        }

        func actions() -> AsyncStream<NowPlayingAction> { stream }
    }

    private func makeApp() -> (MockAppContext, MockNowPlaying) {
        let app = MockAppContext()
        let nowPlaying = MockNowPlaying()
        app.use(NowPlayingPlugin(nowPlaying))
        return (app, nowPlaying)
    }

    private func dispatch(
        _ app: MockAppContext,
        _ command: String,
        _ json: String = "{}"
    ) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: Data(json.utf8))
        let ctx = CommandContext(invocation: inv, caller: .agent, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    @Test("metadata reaches the platform")
    func metadata() async {
        let (app, nowPlaying) = makeApp()
        let json = #"{"metadata":{"title":"Chapter 1","artist":"A Book","album":"Vol 1"}}"#
        guard case .ok = await dispatch(app, "__audio.nowPlaying.setMetadata", json) else {
            Issue.record("expected ok"); return
        }
        #expect(nowPlaying.metadata?.title == "Chapter 1")
        #expect(nowPlaying.metadata?.artist == "A Book")
    }

    @Test("artwork arrives as bytes, and the mime type rides along")
    func artwork() async {
        let (app, nowPlaying) = makeApp()
        // A one-pixel PNG, base64 — the shape the polyfill produces after
        // fetching the page's own artwork URL.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let json = """
        {"metadata":{"title":"Chapter 1","artwork":{"data":"\(png)","mimeType":"image/png"}}}
        """
        guard case .ok = await dispatch(app, "__audio.nowPlaying.setMetadata", json) else {
            Issue.record("expected ok"); return
        }
        let artwork = nowPlaying.metadata?.artwork
        #expect(artwork?.mimeType == "image/png")
        #expect(artwork?.data == Data(base64Encoded: png))
        // PNG magic, so a base64 decode that silently produced garbage fails here.
        #expect(artwork?.data.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47]) == true)
    }

    /// The polyfill publishes a track's text first and its image second, so a
    /// payload without artwork is the *normal* first half of a track change —
    /// it has to clear, or the previous cover outlives its track.
    @Test("metadata without artwork clears it rather than keeping the last one")
    func artworkCleared() async {
        let (app, nowPlaying) = makeApp()
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        _ = await dispatch(
            app, "__audio.nowPlaying.setMetadata",
            #"{"metadata":{"title":"one","artwork":{"data":"\#(png)"}}}"#
        )
        #expect(nowPlaying.metadata?.artwork != nil)
        _ = await dispatch(app, "__audio.nowPlaying.setMetadata", #"{"metadata":{"title":"two"}}"#)
        #expect(nowPlaying.metadata?.artwork == nil)
    }

    @Test("clearing metadata is distinct from never setting it")
    func clearMetadata() async {
        let (app, nowPlaying) = makeApp()
        _ = await dispatch(app, "__audio.nowPlaying.setMetadata", #"{"metadata":{"title":"x"}}"#)
        _ = await dispatch(app, "__audio.nowPlaying.setMetadata", #"{"metadata":null}"#)
        #expect(nowPlaying.metadata == nil)
    }

    @Test("an unknown playback state is refused")
    func unknownState() async {
        let (app, nowPlaying) = makeApp()
        guard case let .failure(error) = await dispatch(
            app, "__audio.nowPlaying.setPlaybackState", #"{"state":"humming"}"#
        ) else {
            Issue.record("expected a failure"); return
        }
        #expect(error.code == BridgeError.decode)
        #expect(nowPlaying.state == .none)
    }

    @Test("only actions the page handles are published")
    func actionsArePublished() async {
        let (app, nowPlaying) = makeApp()
        // `skipad` is a real W3C action with no place in a transport row: it is
        // dropped rather than failing the call, so a page registering one
        // doesn't lose the handlers registered alongside it.
        let json = #"{"actions":["play","pause","skipad","nexttrack"]}"#
        guard case .ok = await dispatch(app, "__audio.nowPlaying.setActions", json) else {
            Issue.record("expected ok"); return
        }
        #expect(nowPlaying.publishedActions == [.play, .pause, .nextTrack])
    }

    @Test("an OS-triggered action is forwarded to the page")
    func actionsReachTheBus() async throws {
        let (app, nowPlaying) = makeApp()
        // The pump is detached from the MainActor deliberately (Android's main
        // thread never drains libdispatch's main queue); this asserts it runs
        // and reaches the bus at all.
        final class Received: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ value: String) { lock.withLock { values.append(value) } }
            var all: [String] {
                lock.withLock { values }
            }
        }
        let received = Received()
        let subscription = app.events.subscribe(NowPlayingPlugin.actionChannel) { payload in
            if let event = try? JSONDecoder().decode(NowPlayingActionEvent.self, from: payload) {
                received.append(event.action)
            }
        }
        defer { subscription.cancel() }

        nowPlaying.continuation.yield(.pause)
        // The pump hops through a detached task, so give it a moment.
        for _ in 0 ..< 50 where received.all.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(received.all == ["pause"])
    }
}

/// The runtime warning for an app that plays audio and never declares a
/// policy. It exists because that app works on the machine it was written on
/// and stops when backgrounded on iOS, with nothing reporting it.
@Suite("audio policy diagnostic")
struct AudioPolicyDiagnosticTests {
    private var bridge: String {
        (try? BridgeScript.source()) ?? ""
    }

    /// Both halves of the pairing have to be present, or the warning is either
    /// noise (fires without audio) or useless (never fires).
    @Test("it warns only when audio is sounding and the type is still the default")
    func firesOnThePairing() {
        #expect(bridge.contains(#"if (type !== "auto") return;"#))
        // Media elements: a capturing listener, since `play` doesn't bubble.
        #expect(bridge.contains(#"document.addEventListener("play", reportAudioPolicy, true)"#))
        // Web Audio: only once the context is actually producing sound.
        #expect(bridge.contains(#"if (this.state === "running") reportAudioPolicy();"#))
    }

    /// A page may set the type in the same handler that starts the sound, in
    /// either order; without the grace window the warning is a race the
    /// developer can't do anything about.
    @Test("a grace window keeps set-after-play from warning")
    func gracePeriod() {
        #expect(bridge.contains("AUDIO_POLICY_GRACE_MS"))
        #expect(bridge.contains("}, AUDIO_POLICY_GRACE_MS);"))
    }

    /// Rendering to a buffer isn't playback, and an app that does it shouldn't
    /// be told to declare a policy it has no use for.
    @Test("OfflineAudioContext is left alone")
    func offlineUntouched() {
        // The list of globals that get observed — not the prose around it,
        // which names OfflineAudioContext to explain the omission.
        #expect(bridge.contains(#"for (const name of ["AudioContext", "webkitAudioContext"])"#))
    }

    /// The observation subclasses a page global, so it has to be invisible to
    /// a page that inspects or extends it.
    @Test("the observed AudioContext keeps its name and stays subclassable")
    func transparentSubclass() {
        #expect(bridge.contains("class extends Original"))
        #expect(bridge.contains(#"Object.defineProperty(Observed, "name", { value: name })"#))
    }

    @Test("the message names every type the Swift enum offers as a remedy")
    func namesTheRemedies() {
        // The three a page realistically picks; a warning that says "set the
        // type" without saying to what is a warning nobody acts on.
        for type in [AudioSessionType.playback, .ambient, .transient] {
            #expect(bridge.contains("'\(type.rawValue)'"), "the warning doesn't mention \(type.rawValue)")
        }
    }
}

/// The `mediaSession` half of the polyfill, asserted against `bridge.js`.
@Suite("navigator.mediaSession polyfill")
struct MediaSessionPolyfillTests {
    private var bridge: String {
        (try? BridgeScript.source()) ?? ""
    }

    @Test("it installs only where the engine lacks the API")
    func onlyWhenAbsent() {
        #expect(bridge.contains(#"!("mediaSession" in navigator)"#))
    }

    @Test("MediaMetadata is defined too, since it's missing wherever mediaSession is")
    func definesMediaMetadata() {
        #expect(bridge.contains("globalThis.MediaMetadata = class MediaMetadata"))
    }

    @Test("the action channel agrees with the plugin's")
    func channelAgrees() {
        // Two string literals, two languages, two files.
        #expect(bridge.contains(#"on("\#(NowPlayingPlugin.actionChannel)""#))
    }

    @Test("every playback state the Swift enum knows is in the JS set")
    func statesAgree() {
        for state in NowPlayingPlaybackState.allCases {
            #expect(bridge.contains("\"\(state.rawValue)\""), "bridge.js is missing \(state.rawValue)")
        }
    }

    /// Artwork is fetched in the page rather than passed as a URL, because the
    /// page's URL is the only one that resolves — see `NowPlayingArtwork`.
    @Test("artwork is fetched in the document and sent as bytes")
    func artworkFetchedInPage() {
        #expect(bridge.contains("const readArtwork = async (entry)"))
        #expect(bridge.contains("await fetch(entry.src)"))
        #expect(bridge.contains("readAsDataURL(blob)"))
    }

    /// Without the generation guard a slow fetch for the previous track lands
    /// its cover on the current one — the failure is invisible in a unit test
    /// and obvious on a lock screen.
    @Test("a stale artwork fetch can't land on the next track")
    func artworkGenerationGuard() {
        #expect(bridge.contains("const generation = ++metadataGeneration"))
        #expect(bridge.contains("if (generation !== metadataGeneration) return"))
    }

    @Test("oversized artwork is skipped rather than pushed through the bridge")
    func artworkSizeCap() {
        #expect(bridge.contains("ARTWORK_MAX_BYTES"))
        #expect(bridge.contains("blob.size > ARTWORK_MAX_BYTES"))
    }
}
