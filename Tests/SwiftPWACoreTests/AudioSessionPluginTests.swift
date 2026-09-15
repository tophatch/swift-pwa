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
