import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("BiometricAuthPlugin")
@MainActor
struct BiometricAuthPluginTests {
    private func makeApp() -> (MockAppContext, MockBiometricAuth) {
        let app = MockAppContext()
        let auth = MockBiometricAuth()
        app.use(BiometricAuthPlugin(auth))
        return (app, auth)
    }

    private func dispatch(_ app: MockAppContext, _ command: String, _ payload: String) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: Data(payload.utf8))
        let ctx = CommandContext(invocation: inv, originWindow: nil, appContext: app)
        return await app.registry.dispatch(ctx)
    }

    @Test("biometric.canAuthenticate reports the kind from the backend")
    func availability() async throws {
        let (app, auth) = makeApp()
        auth.nextAvailability = BiometricAvailability(available: true, kind: .faceID)
        let result = await dispatch(app, "biometric.canAuthenticate", "{}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(BiometricAvailability.self, from: data)
        #expect(out.available == true)
        #expect(out.kind == .faceID)
    }

    @Test("biometric.canAuthenticate surfaces an unavailable reason")
    func unavailable() async throws {
        let (app, auth) = makeApp()
        auth.nextAvailability = BiometricAvailability(
            available: false,
            kind: .none,
            reason: "not enrolled"
        )
        let result = await dispatch(app, "biometric.canAuthenticate", "{}")
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(BiometricAvailability.self, from: data)
        #expect(out.available == false)
        #expect(out.reason == "not enrolled")
    }

    @Test("biometric.authenticate forwards reason and reports success")
    func authenticateOK() async throws {
        let (app, auth) = makeApp()
        auth.nextResult = BiometricAuthResult(authenticated: true)
        let payload = #"{"reason":"unlock the journal"}"#
        let result = await dispatch(app, "biometric.authenticate", payload)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(BiometricAuthResult.self, from: data)
        #expect(out.authenticated == true)
        #expect(auth.actions == [.authenticate(.init(reason: "unlock the journal"))])
    }

    @Test("biometric.authenticate threads cancel through as a non-throwing result")
    func authenticateCancel() async throws {
        let (app, auth) = makeApp()
        auth.nextResult = BiometricAuthResult(authenticated: false, error: "cancelled")
        let result = await dispatch(app, "biometric.authenticate", #"{"reason":"x"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(BiometricAuthResult.self, from: data)
        #expect(out.authenticated == false)
        #expect(out.error == "cancelled")
    }

    @Test("biometric.canAuthenticate defaults to the biometrics-only policy")
    func availabilityDefaultsToBiometricsOnly() async {
        let (app, auth) = makeApp()
        _ = await dispatch(app, "biometric.canAuthenticate", "null")
        #expect(auth.actions == [.canAuthenticate(.init(allowDeviceCredential: false))])
    }

    @Test("biometric.canAuthenticate forwards allowDeviceCredential")
    func availabilityWithDeviceCredential() async {
        let (app, auth) = makeApp()
        _ = await dispatch(app, "biometric.canAuthenticate", #"{"allowDeviceCredential":true}"#)
        #expect(auth.actions == [.canAuthenticate(.init(allowDeviceCredential: true))])
    }

    @Test("biometric.authenticate forwards allowDeviceCredential")
    func authenticateWithDeviceCredential() async {
        let (app, auth) = makeApp()
        let payload = #"{"reason":"unlock","allowDeviceCredential":true}"#
        _ = await dispatch(app, "biometric.authenticate", payload)
        #expect(auth.actions == [.authenticate(.init(reason: "unlock", allowDeviceCredential: true))])
    }

    @Test("a page written before the flag existed still decodes")
    func authenticateArgsBackCompat() throws {
        let args = try JSONDecoder().decode(BiometricAuthArgs.self, from: Data(#"{"reason":"x"}"#.utf8))
        #expect(args.allowDeviceCredential == false)
    }

    @Test("BiometricKind round-trips through JSON")
    func kindCodable() throws {
        let snap = BiometricAvailability(available: true, kind: .windowsHello)
        let json = try JSONEncoder().encode(snap)
        #expect(String(data: json, encoding: .utf8)?.contains("\"windowsHello\"") == true)
        let back = try JSONDecoder().decode(BiometricAvailability.self, from: json)
        #expect(back.kind == .windowsHello)
    }
}
