import Foundation
@testable import SwiftPWACore
import Testing

@Suite("permission policy")
struct PermissionPolicyTests {
    @Test("nothing is permitted until it is declared")
    func undeclaredIsDenied() {
        let policy = PermissionPolicy()
        #expect(policy.decide(.microphone, origin: "pwa://localhost") == .deny(.undeclared))
    }

    @Test("a declared permission is allowed through to the platform")
    func declaredIsAllowed() {
        let policy = PermissionPolicy()
        policy.declare(.microphone)
        #expect(policy.decide(.microphone, origin: "pwa://localhost") == .allow)
        // Declaring one doesn't declare its neighbour.
        #expect(policy.decide(.camera, origin: "pwa://localhost") == .deny(.undeclared))
    }

    @Test("declarations accumulate rather than replace")
    func declarationsAccumulate() {
        let policy = PermissionPolicy()
        policy.declare(.microphone)
        policy.declare(.geolocation, .camera)
        #expect(policy.declaredPermissions == [.microphone, .geolocation, .camera])
    }

    @Test("the veto refuses a declared permission, and says so distinguishably")
    func vetoRefusesDeclared() {
        let policy = PermissionPolicy()
        policy.declare(.microphone, .camera)
        policy.setVeto { permission, _ in permission == .microphone }
        #expect(policy.decide(.microphone, origin: "pwa://localhost") == .deny(.vetoed))
        #expect(policy.decide(.camera, origin: "pwa://localhost") == .allow)
    }

    @Test("the veto sees the requesting origin")
    func vetoSeesOrigin() {
        let policy = PermissionPolicy()
        policy.declare(.geolocation)
        policy.setVeto { _, origin in origin.hasPrefix("https://") }
        #expect(policy.decide(.geolocation, origin: "pwa://localhost") == .allow)
        #expect(policy.decide(.geolocation, origin: "https://example.test") == .deny(.vetoed))
    }

    @Test("a veto can be removed")
    func vetoIsRemovable() {
        let policy = PermissionPolicy()
        policy.declare(.camera)
        policy.setVeto { _, _ in true }
        #expect(policy.decide(.camera, origin: "o") == .deny(.vetoed))
        policy.setVeto(nil)
        #expect(policy.decide(.camera, origin: "o") == .allow)
    }

    // MARK: - Requests that carry several permissions at once

    @Test("an all-of request needs every permission — getUserMedia({audio, video})")
    func allOfNeedsEvery() {
        let policy = PermissionPolicy()
        policy.declare(.microphone)
        // One WebKit request for both; the backend can only allow or deny it
        // whole, so a half-declared app must not get a camera along with a mic.
        #expect(policy.decide(all: [.microphone, .camera], origin: "o") == .deny(.undeclared))
        policy.declare(.camera)
        #expect(policy.decide(all: [.microphone, .camera], origin: "o") == .allow)
    }

    @Test("an all-of request reports a veto over a grant")
    func allOfReportsVeto() {
        let policy = PermissionPolicy()
        policy.declare(.microphone, .camera)
        policy.setVeto { permission, _ in permission == .camera }
        #expect(policy.decide(all: [.microphone, .camera], origin: "o") == .deny(.vetoed))
    }

    @Test("an unclassifiable request is refused, not waved through")
    func emptyAllOfIsDenied() {
        let policy = PermissionPolicy()
        policy.declare(DevicePermission.allCases)
        #expect(policy.decide(all: [], origin: "o") == .deny(.undeclared))
    }

    @Test("an any-of request needs only one — enumerateDevices() labels")
    func anyOfNeedsOne() {
        let policy = PermissionPolicy()
        #expect(policy.decide(any: [.camera, .microphone], origin: "o") == .deny(.undeclared))
        policy.declare(.microphone)
        #expect(policy.decide(any: [.camera, .microphone], origin: "o") == .allow)
    }

    @Test("an any-of request is refused when every candidate is vetoed")
    func anyOfHonoursVeto() {
        let policy = PermissionPolicy()
        policy.declare(.camera, .microphone)
        policy.setVeto { _, _ in true }
        #expect(policy.decide(any: [.camera, .microphone], origin: "o") == .deny(.vetoed))
    }

    // MARK: - Wire shape

    @Test("permission names are the page's vocabulary, and stay stable")
    func rawValuesAreStable() {
        // These names travel into `pwa.json` and the diagnostics, so a rename
        // is a breaking change rather than a tidy-up.
        #expect(Set(DevicePermission.allCases.map(\.rawValue)) == [
            "camera", "microphone", "geolocation", "notifications", "bluetooth", "allFiles"
        ])
    }

    // MARK: - The runtime tier (#243)

    /// A test double standing in for a backend's OS seam.
    private final class StubAuthority: DevicePermissionAuthority, @unchecked Sendable {
        var answer: PermissionState?
        var requested: [DevicePermission] = []
        init(answer: PermissionState?) { self.answer = answer }
        func state(of _: DevicePermission) async -> PermissionState? { answer }
        func request(_ permission: DevicePermission) async -> PermissionState? {
            requested.append(permission)
            answer = .granted
            return answer
        }
    }

    @Test("an undeclared permission is unavailable, not denied")
    func statusUndeclaredIsUnavailable() async {
        let policy = PermissionPolicy()
        policy.setAuthority(StubAuthority(answer: .granted))
        // The difference is the whole point: `denied` is worth a button,
        // `unavailable` never becomes `granted` on this build.
        #expect(await policy.status(.allFiles) == .unavailable)
        #expect(await policy.request(.allFiles) == .unavailable)
    }

    @Test("a vetoed permission is unavailable, and is never asked about")
    func statusVetoedIsUnavailable() async {
        let policy = PermissionPolicy()
        policy.declare(.allFiles)
        let authority = StubAuthority(answer: .denied)
        policy.setAuthority(authority)
        policy.setVeto { permission, _ in permission == .allFiles }
        #expect(await policy.request(.allFiles) == .unavailable)
        // The app ruled it out, so the user was never put in front of a prompt.
        #expect(authority.requested.isEmpty)
    }

    @Test("with no authority installed, a declared permission is granted")
    func statusWithoutAuthority() async {
        // Linux, Windows and macOS install none: nothing stands between a
        // declared app and files it can already open by path.
        let policy = PermissionPolicy()
        policy.declare(.allFiles)
        #expect(await policy.status(.allFiles) == .granted)
        #expect(await policy.request(.allFiles) == .granted)
    }

    @Test("the backend's answer wins, and a request routes to it")
    func statusFromAuthority() async {
        let policy = PermissionPolicy()
        policy.declare(.allFiles)
        let authority = StubAuthority(answer: .denied)
        policy.setAuthority(authority)
        #expect(await policy.status(.allFiles) == .denied)
        #expect(await policy.request(.allFiles) == .granted)
        #expect(authority.requested == [.allFiles])
    }

    @Test("a permission the backend has no opinion on falls back to granted")
    func statusAuthorityAbstains() async {
        let policy = PermissionPolicy()
        policy.declare(.camera)
        policy.setAuthority(StubAuthority(answer: nil))
        // Camera consent is reached through the web API's own seam; the
        // runtime tier has nothing to add and must not claim otherwise.
        #expect(await policy.status(.camera) == .granted)
    }
}
