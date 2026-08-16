import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// A provider that hands back a fixed position, and records whether it was
/// asked at all — the point of most of these tests is that a refusal never
/// reaches the hardware.
private final class StubGeolocation: GeolocationProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int {
        lock.withLock { _calls }
    }

    let fix = GeoFix(latitude: 60.17, longitude: 24.94, accuracy: 12, timestamp: 1_700_000_000)

    func current(_: GeoRequest) async throws -> GeoFix {
        lock.withLock { _calls += 1 }
        return fix
    }

    func watch(_: GeoRequest) -> AsyncThrowingStream<GeoFix, any Error> {
        lock.withLock { _calls += 1 }
        let fix = fix
        return AsyncThrowingStream { continuation in
            continuation.yield(fix)
            continuation.finish()
        }
    }
}

@Suite("geo plugin")
@MainActor
struct GeoPluginTests {
    private func makeApp(
        declare: Bool, veto: Bool = false
    ) -> (MockAppContext, StubGeolocation) {
        let app = MockAppContext()
        let provider = StubGeolocation()
        if declare { app.permissions.declare(.geolocation) }
        if veto { app.permissions.setVeto { _, _ in true } }
        app.use(GeoPlugin(provider))
        return (app, provider)
    }

    /// Dispatch `geo.current` the way the bridge does, so the test exercises
    /// the registered handler rather than the plugin's internals.
    private func dispatchCurrent(
        _ app: MockAppContext, payload: String = "{}"
    ) async -> InvocationResult {
        let invocation = Invocation(id: 1, command: "geo.current", payload: Data(payload.utf8))
        return await app.registry.dispatch(
            CommandContext(invocation: invocation, originWindow: nil, appContext: app)
        )
    }

    @Test("geo.current returns a fix when the permission is declared")
    func currentWhenDeclared() async throws {
        let (app, provider) = makeApp(declare: true)
        let result = await dispatchCurrent(app, payload: "{\"accuracy\":\"high\"}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let fix = try JSONDecoder().decode(GeoFix.self, from: data)
        #expect(fix.latitude == provider.fix.latitude)
        #expect(fix.accuracy == 12)
        #expect(provider.calls == 1)
    }

    @Test("an undeclared app is refused without touching the hardware")
    func undeclaredIsRefused() async {
        let (app, provider) = makeApp(declare: false)
        guard case .failure = await dispatchCurrent(app) else {
            Issue.record("expected a refusal"); return
        }
        // The refusal must come before the provider — spinning up CoreLocation
        // or GeoClue for a request that's already decided is exactly the cost
        // the gate exists to avoid.
        #expect(provider.calls == 0)
    }

    @Test("the refusal names the missing declaration")
    func refusalIsDiagnostic() async {
        let (app, _) = makeApp(declare: false)
        guard case let .failure(error) = await dispatchCurrent(app) else {
            Issue.record("expected a refusal"); return
        }
        #expect(error.code == "E_GEO_DENIED")
        #expect(error.message.contains("geolocation"))
    }

    @Test("an app-level veto refuses a declared permission, and says which it is")
    func vetoIsRefused() async {
        let (app, provider) = makeApp(declare: true, veto: true)
        guard case let .failure(error) = await dispatchCurrent(app) else {
            Issue.record("expected a refusal"); return
        }
        #expect(error.code == "E_GEO_DENIED")
        // Distinguishable from the undeclared case: the user can fix this one
        // in the app's own settings.
        #expect(error.message.contains("turned location off"))
        #expect(provider.calls == 0)
    }

    @Test("the plugin can't be used to route around the policy")
    func pluginHonoursTheSameGateAsTheWebAPI() async {
        // The whole point of the two ceilings is that they're not bypassable.
        // A `geo.*` that ignored them would be a documented hole in the app's
        // own privacy switch.
        let (app, provider) = makeApp(declare: false, veto: false)
        guard case .failure = await dispatchCurrent(app) else {
            Issue.record("expected a refusal"); return
        }
        #expect(provider.calls == 0)
    }

    // MARK: - Contract shape

    @Test("a fix serializes in the web platform's vocabulary")
    func fixWireShape() throws {
        let fix = GeoFix(
            latitude: 1.5, longitude: -2.5, accuracy: 30,
            altitude: 12, altitudeAccuracy: 5, heading: 90, speed: 1.2,
            timestamp: 1_700_000_000
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try String(data: encoder.encode(fix), encoding: .utf8) ?? ""
        // Names match `GeolocationCoordinates` so moving off navigator.geolocation
        // doesn't mean relearning the shape.
        for key in ["latitude", "longitude", "accuracy", "altitude", "altitudeAccuracy", "heading", "speed"] {
            #expect(json.contains("\"\(key)\""))
        }
    }

    @Test("the none provider reports unavailable rather than hanging")
    func noneProvider() async {
        let provider = NoneGeolocationProvider()
        await #expect(throws: GeoError.self) {
            try await provider.current(GeoRequest())
        }
    }

    @Test("an argument-less call decodes — invoke('geo.current') with no options")
    func emptyPayloadDecodes() throws {
        // Swift's synthesized Decodable ignores property defaults, so without a
        // hand-written initializer the most natural JS call fails E_DECODE.
        let request = try JSONDecoder().decode(GeoRequest.self, from: Data("{}".utf8))
        #expect(request.accuracy == .balanced)
        #expect(request.timeoutSeconds == nil)
    }

    @Test("accuracy is a coarse hint, not a metre budget")
    func accuracyValues() {
        #expect(Set(GeoAccuracy.allCases.map(\.rawValue)) == ["high", "balanced"])
        // Defaulting to balanced: it's what most apps need and what a user is
        // likeliest to consent to.
        #expect(GeoRequest().accuracy == .balanced)
    }
}
