import Foundation
@testable import SwiftPWACLISupport
import Testing

/// Unit tests for the pure `--team` → signing-inputs matching logic (no
/// keychain / on-disk profiles required).
@Suite("iOS --team signing resolution")
struct IOSSigningResolverTests {
    private let team = "ABCDE12345"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var future: Date {
        now.addingTimeInterval(86400)
    }
    private var past: Date {
        now.addingTimeInterval(-86400)
    }

    private func profile(
        teamIDs: [String]? = nil, appID: String, expiry: Date? = nil, devices: [String]? = nil
    ) -> [String: Any] {
        var p: [String: Any] = [
            "TeamIdentifier": teamIDs ?? [team],
            "Entitlements": ["application-identifier": appID]
        ]
        if let expiry { p["ExpirationDate"] = expiry }
        if let devices { p["ProvisionedDevices"] = devices }
        return p
    }

    /// Two real-shaped UDIDs: the modern `<8 hex>-<16 hex>` form and the
    /// 40-hex form older devices still carry.
    private let deviceA = "00008120-000A1B2C3D4E5678"
    private let deviceB = "1a2b3c4d5e6f708192a3b4c5d6e7f80912345678"

    @Test("parseIdentities reads (hash, name) pairs and ignores the footer")
    func parseIdentities() {
        let out = """
          1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Apple Development: dev@example.com (ABCDE12345)"
          2) 1122334455667788990011223344556677889900 "Apple Distribution: Example Inc (ABCDE12345)"
             2 valid identities found
        """
        let ids = IOSSigning.parseIdentities(out)
        #expect(ids.count == 2)
        #expect(ids[0].name == "Apple Development: dev@example.com (ABCDE12345)")
        #expect(ids[1].hash == "1122334455667788990011223344556677889900")
    }

    @Test("selectIdentity prefers Apple Development and matches the team id")
    func selectIdentity() {
        let ids = [
            (hash: "h1", name: "Apple Distribution: Example Inc (ABCDE12345)"),
            (hash: "h2", name: "Apple Development: dev@example.com (ABCDE12345)"),
            (hash: "h3", name: "Apple Development: other@example.com (ZZZZZ99999)")
        ]
        #expect(IOSSigning.selectIdentity(team: team, from: ids) == "Apple Development: dev@example.com (ABCDE12345)")
        #expect(IOSSigning.selectIdentity(team: "NOPE000000", from: ids) == nil)
    }

    @Test("profileMatches honors bundle id, team, wildcard, and expiry")
    func profileMatches() {
        let exact = profile(appID: "\(team).com.example.app", expiry: future)
        #expect(IOSSigning.profileMatches(bundleID: "com.example.app", team: team, plist: exact, now: now))
        #expect(!IOSSigning.profileMatches(bundleID: "com.example.other", team: team, plist: exact, now: now))

        let wildcard = profile(appID: "\(team).*", expiry: future)
        #expect(IOSSigning.profileMatches(bundleID: "com.anything.here", team: team, plist: wildcard, now: now))

        let wrongTeam = profile(teamIDs: ["ZZZZZ99999"], appID: "ZZZZZ99999.com.example.app", expiry: future)
        #expect(!IOSSigning.profileMatches(bundleID: "com.example.app", team: team, plist: wrongTeam, now: now))

        let expired = profile(appID: "\(team).com.example.app", expiry: past)
        #expect(!IOSSigning.profileMatches(bundleID: "com.example.app", team: team, plist: expired, now: now))
    }

    @Test("bestProfile prefers an exact match over a wildcard")
    func bestProfilePrefersExact() {
        let wildcardURL = URL(fileURLWithPath: "/tmp/wild.mobileprovision")
        let exactURL = URL(fileURLWithPath: "/tmp/exact.mobileprovision")
        let candidates = [
            (url: wildcardURL, plist: profile(appID: "\(team).*", expiry: future)),
            (url: exactURL, plist: profile(appID: "\(team).com.example.app", expiry: future))
        ]
        #expect(IOSSigning
            .bestProfile(bundleID: "com.example.app", team: team, candidates: candidates, now: now)
            .profile == exactURL)
    }

    @Test("bestProfile picks the latest expiry among equal-specificity matches")
    func bestProfilePrefersLatest() {
        let soonURL = URL(fileURLWithPath: "/tmp/soon.mobileprovision")
        let laterURL = URL(fileURLWithPath: "/tmp/later.mobileprovision")
        let candidates = [
            (url: soonURL, plist: profile(appID: "\(team).com.example.app", expiry: future)),
            (
                url: laterURL,
                plist: profile(appID: "\(team).com.example.app", expiry: future.addingTimeInterval(1_000_000))
            )
        ]
        #expect(IOSSigning
            .bestProfile(bundleID: "com.example.app", team: team, candidates: candidates, now: now)
            .profile == laterURL)
    }

    @Test("provisionedDevices is nil for a profile that lists none")
    func provisionedDevices() {
        let development = profile(appID: "\(team).com.example.app", expiry: future, devices: [deviceA])
        #expect(IOSSigning.provisionedDevices(from: development) == [deviceA.uppercased()])
        // A distribution profile carries no device list — that means "any
        // device", not "no device", so it must not read as empty.
        let distribution = profile(appID: "\(team).com.example.app", expiry: future)
        #expect(IOSSigning.provisionedDevices(from: distribution) == nil)
        #expect(IOSSigning.profileCovers(deviceUDID: deviceB, plist: distribution))
    }

    @Test("profileCovers matches a listed device, case-insensitively")
    func profileCovers() {
        let p = profile(appID: "\(team).com.example.app", expiry: future, devices: [deviceA, deviceB])
        #expect(IOSSigning.profileCovers(deviceUDID: deviceA, plist: p))
        #expect(IOSSigning.profileCovers(deviceUDID: deviceA.lowercased(), plist: p))
        #expect(IOSSigning.profileCovers(deviceUDID: deviceB.uppercased(), plist: p))
        #expect(!IOSSigning.profileCovers(deviceUDID: "00008120-FFFFFFFFFFFFFFFF", plist: p))
    }

    @Test("bestProfile rejects a current profile that doesn't list the target device")
    func bestProfileExcludesForeignDevice() {
        // The reported shape: a free personal team mints a profile per device,
        // so the profile on disk is exact, unexpired and correctly signed —
        // and still uninstallable on the second device (0xe8008012).
        let otherDeviceURL = URL(fileURLWithPath: "/tmp/other-device.mobileprovision")
        let candidates = [(
            url: otherDeviceURL,
            plist: profile(appID: "\(team).com.example.app", expiry: future, devices: [deviceB])
        )]
        let choice = IOSSigning.bestProfile(
            bundleID: "com.example.app", team: team, deviceUDID: deviceA, candidates: candidates, now: now
        )
        #expect(choice.profile == nil)
        #expect(choice.excludedByDevice == [otherDeviceURL])

        // With no device known, nothing is filtered — a plain `build` behaves
        // exactly as it did.
        #expect(IOSSigning
            .bestProfile(bundleID: "com.example.app", team: team, candidates: candidates, now: now)
            .profile == otherDeviceURL)
    }

    @Test("bestProfile prefers a device-covering profile over an exact-but-foreign one")
    func bestProfilePrefersCoveringDevice() {
        // Specificity only breaks ties among *installable* profiles: an exact
        // app-id match that lists the wrong device loses to a wildcard that
        // lists the right one.
        let exactWrongDevice = URL(fileURLWithPath: "/tmp/exact.mobileprovision")
        let wildcardRightDevice = URL(fileURLWithPath: "/tmp/wild.mobileprovision")
        let candidates = [
            (
                url: exactWrongDevice,
                plist: profile(appID: "\(team).com.example.app", expiry: future, devices: [deviceB])
            ),
            (url: wildcardRightDevice, plist: profile(appID: "\(team).*", expiry: future, devices: [deviceA]))
        ]
        let choice = IOSSigning.bestProfile(
            bundleID: "com.example.app", team: team, deviceUDID: deviceA, candidates: candidates, now: now
        )
        #expect(choice.profile == wildcardRightDevice)
        #expect(choice.excludedByDevice == [exactWrongDevice])
    }

    @Test("isDeviceUDID tells a UDID from a device name")
    func isDeviceUDID() {
        #expect(IOSSigning.isDeviceUDID(deviceA))
        #expect(IOSSigning.isDeviceUDID(deviceB))
        #expect(IOSSigning.isDeviceUDID(deviceA.lowercased()))
        // `--device` takes a name too, and passes an unlisted value straight
        // through as the udid — matching one of these against a profile's
        // device list would reject every profile.
        #expect(!IOSSigning.isDeviceUDID("Test iPad"))
        #expect(!IOSSigning.isDeviceUDID("iPad"))
        #expect(!IOSSigning.isDeviceUDID(""))
        #expect(!IOSSigning.isDeviceUDID("00008120-000A1B2C3D4E567"))
        #expect(!IOSSigning.isDeviceUDID("zzzz8120-000A1B2C3D4E5678"))
    }

    @Test("build parses --team")
    func buildParsesTeam() throws {
        let cmd = try Build.parse(["--target", "ios", "--team", "ABCDE12345"])
        #expect(cmd.team == "ABCDE12345")
    }
}
