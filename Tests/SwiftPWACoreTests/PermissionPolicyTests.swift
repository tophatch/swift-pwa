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
        policy.declare(WebPermission.allCases)
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
        #expect(Set(WebPermission.allCases.map(\.rawValue)) == [
            "camera", "microphone", "geolocation", "notifications"
        ])
    }
}
